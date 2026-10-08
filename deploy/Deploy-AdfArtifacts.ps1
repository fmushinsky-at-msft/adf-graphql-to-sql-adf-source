#Requires -Version 7.5
<#
.SYNOPSIS
    Deploys the Data Factory ARM template exported by the build to one environment.

.DESCRIPTION
    Release half of the "new CI/CD flow" for Azure Data Factory
    (https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-improvements).
    The build exports the factory's artifacts once; this script deploys that same template to an
    environment, using the environment's own parameter values:

      1. Merges deploy/environments/<Environment>.json over the template's parameters.
      2. Checks that the target factory exists and has the expected managed identity, and that every
         managed identity credential in the template uses an identity attached to the factory.
      3. Refuses to deploy a build older than the last one this workflow deployed there.
      4. Runs the exported PrePostDeploymentScript.ps1 to stop triggers that are about to change.
      5. Deploys the template in Incremental mode.
      6. Runs PrePostDeploymentScript.ps1 again to delete artifacts that are no longer in the
         template and to start triggers.
      7. Checks that the factory now contains exactly the artifacts in the template.

    The template never contains the factory resource itself, so deployments don't change the
    factory's Git configuration, managed identities, networking or encryption settings.

.PARAMETER Environment
    Environment name. Its settings are read from <EnvironmentConfigFolder>/<Environment>.json.

.PARAMETER ArmTemplateFolder
    Folder with ARMTemplateForFactory.json and PrePostDeploymentScript.ps1. Defaults to
    ../ArmTemplate (build artifact layout), then ../build/ArmTemplate (repository layout).

.PARAMETER EnvironmentConfigFolder
    Folder with the environment configuration files. Defaults to the environments folder next to
    this script.

.PARAMETER BuildInfoPath
    build-info.json written by the build. Defaults to ../build-info.json when it exists. Without it,
    the deployment can't be traced to a build and the older-build check is skipped.

.PARAMETER CheckConfigurationOnly
    Check the template and the environment configuration without connecting to Azure.

.PARAMETER ValidateOnly
    Run every check against Azure and preview the changes, without changing anything.

.EXAMPLE
    ./deploy/Deploy-AdfArtifacts.ps1 -Environment prd -CheckConfigurationOnly

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id> -Subscription <subscription-id>
    ./deploy/Deploy-AdfArtifacts.ps1 -Environment prd -ValidateOnly
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Writes GitHub Actions workflow commands and progress for the job log.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$')]
    [string] $Environment,

    [string] $ArmTemplateFolder,

    [string] $EnvironmentConfigFolder = (Join-Path $PSScriptRoot 'environments'),

    [string] $BuildInfoPath,

    [switch] $CheckConfigurationOnly,

    [switch] $ValidateOnly
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$FactoryType = 'Microsoft.DataFactory/factories'

# Artifact kinds that PrePostDeploymentScript.ps1 deletes from the factory when they're no longer in
# the template, in the order it deletes them.
$ArtifactKinds = [ordered]@{
    triggers            = 'Triggers'
    pipelines           = 'Pipelines'
    dataflows           = 'Data flows'
    datasets            = 'Datasets'
    linkedServices      = 'Linked services'
    integrationRuntimes = 'Integration runtimes'
}

$InGitHubActions = $env:GITHUB_ACTIONS -eq 'true'
$ArtifactRoot = Split-Path -Parent $PSScriptRoot

#region Helpers

function Write-Annotation {
    param(
        [Parameter(Mandatory)] [ValidateSet('notice', 'warning', 'error')] [string] $Level,
        [Parameter(Mandatory)] [string] $Message
    )
    if ($InGitHubActions) {
        $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host "::${Level}::$escaped"
    }
    elseif ($Level -eq 'warning') {
        Write-Warning $Message
    }
    else {
        Write-Host "$($Level.ToUpperInvariant()): $Message"
    }
}

function Invoke-LogGroup {
    param([Parameter(Mandatory)] [string] $Title, [Parameter(Mandatory)] [scriptblock] $ScriptBlock)
    Write-Host ($InGitHubActions ? "::group::$Title" : "`n=== $Title")
    try {
        & $ScriptBlock | Out-Host
    }
    finally {
        if ($InGitHubActions) { Write-Host '::endgroup::' }
    }
}

function Resolve-FullPath {
    param([Parameter(Mandatory)] [string] $Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-DisplayPath {
    param([Parameter(Mandatory)] [string] $Path)
    [System.IO.Path]::GetRelativePath($ArtifactRoot, $Path).Replace('\', '/')
}

function Read-JsonFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
    try {
        # -DateKind String keeps date-like strings, such as trigger start times, exactly as written.
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    }
    catch {
        throw "$Description isn't valid JSON ($Path): $($_.Exception.Message)"
    }
}

function Get-ArtifactName {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $ResourceName)
    # The exporter names every resource "[concat(parameters('factoryName'), '/<name>')]", and
    # PrePostDeploymentScript.ps1 relies on that format too.
    if ($ResourceName -match "^\[concat\(parameters\('factoryName'\), '/(?<name>[^']+)'\)\]$") {
        return $Matches['name']
    }
    throw "Unexpected resource name in the ARM template: '$ResourceName'."
}

function Test-ContainsTemplateExpression {
    # True when a value contains a string that ARM evaluates as an expression ("[...]") or
    # unescapes ("[[..."). Such values can't be copied into a parameter file verbatim.
    param($Value)
    if ($Value -is [string]) {
        return $Value.StartsWith('[')
    }
    $children = if ($Value -is [System.Collections.IDictionary]) { $Value.Values } elseif ($Value -is [System.Collections.IList]) { $Value } else { @() }
    foreach ($child in $children) {
        if (Test-ContainsTemplateExpression $child) { return $true }
    }
    return $false
}

function Test-ParameterValueType {
    param([string] $Type, $Value)
    switch ($Type.ToLowerInvariant()) {
        { $_ -in 'string', 'securestring' } { return $Value -is [string] }
        'int' { return $Value -is [long] -or $Value -is [int] -or $Value -is [System.Numerics.BigInteger] }
        'bool' { return $Value -is [bool] }
        { $_ -in 'object', 'secureobject' } { return $Value -is [System.Collections.IDictionary] }
        'array' { return $Value -is [System.Collections.IList] }
        default { return $true }
    }
}

function Format-DisplayValue {
    param($Value)
    $text = ($Value -is [string]) ? $Value : (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
    ($text.Length -gt 120) ? ($text.Substring(0, 117) + '...') : $text
}

function Resolve-TemplateValue {
    # Returns the literal value of a template property: a literal string, or a string parameter
    # reference resolved from the parameter plan. Returns $null when only ARM can tell.
    param($Value, [Parameter(Mandatory)] $Plan)
    if ($Value -isnot [string]) {
        return $null
    }
    if ($Value -match "^\[parameters\('(?<name>[^']+)'\)\]$") {
        $entry = $Plan.Entries[$Matches['name']]
        if ($null -ne $entry -and $entry.Contains('value') -and $entry['value'] -is [string]) {
            return $entry['value']
        }
        return $null
    }
    $Value.StartsWith('[') ? $null : $Value
}

function Get-NameDifference {
    # Names in $From that aren't in $In, compared case-insensitively like Data Factory names.
    param([string[]] $From, [string[]] $In)
    @($From | Where-Object { $_ -and $_ -notin $In })
}

#endregion

#region Template and configuration

function Resolve-TemplateFolder {
    param([string] $Folder)
    $candidates = if ($Folder) {
        @(Resolve-FullPath $Folder)
    }
    else {
        @((Join-Path $ArtifactRoot 'ArmTemplate'), (Join-Path -Path $ArtifactRoot -ChildPath 'build' -AdditionalChildPath 'ArmTemplate'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'ARMTemplateForFactory.json') -PathType Leaf) {
            return $candidate
        }
    }
    throw "ARMTemplateForFactory.json not found in $($candidates -join ' or '). Export the template first (see readme.md), or pass -ArmTemplateFolder."
}

function Read-ArmTemplate {
    param([Parameter(Mandatory)] [string] $Folder)

    $templatePath = Join-Path $Folder 'ARMTemplateForFactory.json'
    $prePostScriptPath = Join-Path $Folder 'PrePostDeploymentScript.ps1'
    $template = Read-JsonFile -Path $templatePath -Description 'ARM template'
    if (-not (Test-Path -LiteralPath $prePostScriptPath -PathType Leaf)) {
        throw "PrePostDeploymentScript.ps1 not found in $Folder. The export writes it next to the ARM template."
    }

    $parameters = $template['parameters']
    if ($parameters -isnot [System.Collections.IDictionary] -or $parameters['factoryName'] -isnot [System.Collections.IDictionary]) {
        throw "$templatePath isn't a Data Factory export: it has no factoryName parameter."
    }

    $artifacts = [ordered]@{}
    foreach ($kind in $ArtifactKinds.Keys) {
        $artifacts[$kind] = [System.Collections.Generic.List[string]]::new()
    }
    $triggerStates = [ordered]@{}
    $credentials = [System.Collections.Generic.List[object]]::new()
    $hasGlobalParameters = $false

    foreach ($resource in @($template['resources'])) {
        $type = [string]$resource['type']
        if ($type -eq $FactoryType) {
            throw 'The ARM template contains the factory resource itself. Deploying it would disconnect the factory from Git and replace its managed identities. Remove includeFactoryTemplate from publish_config.json and rebuild.'
        }
        if (-not $type.StartsWith("$FactoryType/", [StringComparison]::OrdinalIgnoreCase)) {
            throw "The ARM template contains a resource that doesn't belong to a data factory: $type."
        }

        $kind = $type.Substring($FactoryType.Length + 1)
        $name = Get-ArtifactName ([string]$resource['name'])
        $properties = $resource['properties']
        if ($properties -isnot [System.Collections.IDictionary]) {
            $properties = @{}
        }

        if ($ArtifactKinds.Contains($kind)) {
            $artifacts[$kind].Add($name)
            if ($kind -eq 'triggers') {
                $triggerStates[$name] = $properties['runtimeState']
            }
        }
        elseif ($kind -eq 'credentials' -and $properties['type'] -eq 'ManagedIdentity') {
            $typeProperties = $properties['typeProperties']
            $resourceId = if ($typeProperties -is [System.Collections.IDictionary]) { $typeProperties['resourceId'] }
            $credentials.Add([pscustomobject]@{ Name = $name; ResourceId = $resourceId })
        }
        elseif ($kind -eq 'globalparameters') {
            $hasGlobalParameters = $true
        }
    }

    $artifactCount = 0
    foreach ($names in $artifacts.Values) {
        $artifactCount += $names.Count
    }
    if ($artifactCount -eq 0) {
        throw 'The ARM template has no pipelines, datasets, linked services, data flows, triggers or integration runtimes. Refusing to deploy it, because the post-deployment step would then delete every artifact in the target factory.'
    }

    foreach ($file in Get-ChildItem -LiteralPath $Folder -Filter '*_GlobalParameters.json' -File) {
        $globalParameters = Read-JsonFile -Path $file.FullName -Description 'Global parameters file'
        if ($globalParameters -is [System.Collections.IDictionary] -and $globalParameters.Count -gt 0 -and -not $hasGlobalParameters) {
            throw 'The factory has global parameters, but the ARM template leaves them out. Set "includeGlobalParamsTemplate": true in publish_config.json and rebuild.'
        }
    }

    [pscustomobject]@{
        TemplatePath      = $templatePath
        PrePostScriptPath = $prePostScriptPath
        SourceFactoryName = [string]$parameters['factoryName']['defaultValue']
        Parameters        = $parameters
        Artifacts         = $artifacts
        TriggerStates     = $triggerStates
        Credentials       = $credentials
    }
}

function Read-EnvironmentConfig {
    param([Parameter(Mandatory)] [string] $Path)

    $config = Read-JsonFile -Path $Path -Description "Configuration for environment '$Environment'"
    $displayPath = Get-DisplayPath $Path
    if ($config -isnot [System.Collections.IDictionary]) {
        throw "$displayPath must contain a JSON object."
    }

    $allowed = 'description', 'resourceGroupName', 'factoryName', 'isAuthoringFactory', 'factoryIdentity', 'parameters'
    $unknown = @($config.Keys | Where-Object { $_ -cnotin $allowed })
    if ($unknown.Count -gt 0) {
        throw "$displayPath has unknown properties: $($unknown -join ', '). Allowed properties: $($allowed -join ', ')."
    }

    foreach ($key in 'resourceGroupName', 'factoryName') {
        if ($config[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($config[$key])) {
            throw "$displayPath must set $key."
        }
    }
    $factoryName = $config['factoryName']
    if ($factoryName -notmatch '^(?=.{3,63}$)[A-Za-z0-9]+(-[A-Za-z0-9]+)*$') {
        throw "$displayPath has an invalid factoryName: '$factoryName'."
    }
    $resourceGroupName = $config['resourceGroupName']
    if ($resourceGroupName -notmatch '^[-\w.()]{1,90}$' -or $resourceGroupName.EndsWith('.')) {
        throw "$displayPath has an invalid resourceGroupName: '$resourceGroupName'."
    }

    $isAuthoringFactory = $false
    if ($config.Contains('isAuthoringFactory')) {
        if ($config['isAuthoringFactory'] -isnot [bool]) {
            throw "isAuthoringFactory in $displayPath must be true or false."
        }
        $isAuthoringFactory = $config['isAuthoringFactory']
    }

    $systemAssignedPrincipalId = $null
    $userAssignedIdentityIds = @()
    if ($config.Contains('factoryIdentity')) {
        $identity = $config['factoryIdentity']
        if ($identity -isnot [System.Collections.IDictionary]) {
            throw "factoryIdentity in $displayPath must be an object."
        }
        $unknown = @($identity.Keys | Where-Object { $_ -cnotin 'systemAssignedPrincipalId', 'userAssignedIdentityIds' })
        if ($unknown.Count -gt 0) {
            throw "factoryIdentity in $displayPath has unknown properties: $($unknown -join ', '). Allowed properties: systemAssignedPrincipalId, userAssignedIdentityIds."
        }
        if ($identity.Contains('systemAssignedPrincipalId')) {
            $systemAssignedPrincipalId = $identity['systemAssignedPrincipalId']
            $parsed = [guid]::Empty
            if ($systemAssignedPrincipalId -isnot [string] -or -not [guid]::TryParse($systemAssignedPrincipalId, [ref]$parsed)) {
                throw "factoryIdentity.systemAssignedPrincipalId in $displayPath must be a GUID."
            }
        }
        if ($identity.Contains('userAssignedIdentityIds')) {
            if ($identity['userAssignedIdentityIds'] -isnot [System.Collections.IList]) {
                throw "factoryIdentity.userAssignedIdentityIds in $displayPath must be an array."
            }
            $userAssignedIdentityIds = @($identity['userAssignedIdentityIds'])
            foreach ($id in $userAssignedIdentityIds) {
                if ($id -isnot [string] -or $id -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$') {
                    throw "factoryIdentity.userAssignedIdentityIds in $displayPath must contain resource IDs of user-assigned identities (/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<name>)."
                }
            }
        }
    }

    # ARM parameter names are case-insensitive.
    $parameters = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($config.Contains('parameters')) {
        $section = $config['parameters']
        if ($section -isnot [System.Collections.IDictionary]) {
            throw "parameters in $displayPath must be an object."
        }
        foreach ($name in $section.Keys) {
            $entry = $section[$name]
            $isSingleProperty = $entry -is [System.Collections.IDictionary] -and $entry.Count -eq 1
            $isValue = $isSingleProperty -and $entry.Contains('value') -and $null -ne $entry['value']
            $isReference = $isSingleProperty -and $entry.Contains('reference')
            if (-not ($isValue -or $isReference)) {
                throw "Parameter $name in $displayPath must be an object with a single ""value"" or Key Vault ""reference"" property, for example { ""value"": ""..."" }."
            }
            if ($isReference) {
                $reference = $entry['reference']
                $isValidReference = $reference -is [System.Collections.IDictionary] -and
                    $reference['keyVault'] -is [System.Collections.IDictionary] -and
                    $reference['keyVault']['id'] -is [string] -and
                    $reference['secretName'] -is [string]
                if (-not $isValidReference) {
                    throw "Parameter $name in $displayPath has an invalid Key Vault reference. Expected { ""reference"": { ""keyVault"": { ""id"": ""<key vault resource ID>"" }, ""secretName"": ""<secret name>"" } }."
                }
            }
            if ($parameters.ContainsKey($name)) {
                throw "Parameter $name appears more than once in $displayPath (parameter names are case-insensitive)."
            }
            $parameters[$name] = $entry
        }
    }

    [pscustomobject]@{
        Path                      = $Path
        DisplayPath               = $displayPath
        ResourceGroupName         = $resourceGroupName
        FactoryName               = $factoryName
        IsAuthoringFactory        = $isAuthoringFactory
        SystemAssignedPrincipalId = $systemAssignedPrincipalId
        UserAssignedIdentityIds   = $userAssignedIdentityIds
        Parameters                = $parameters
    }
}

function Get-ParameterPlan {
    # Decides the value of every template parameter for this environment.
    param([Parameter(Mandatory)] $Template, [Parameter(Mandatory)] $Config)

    $errors = [System.Collections.Generic.List[string]]::new()
    if ($Config.Parameters.ContainsKey('factoryName')) {
        $errors.Add('Set the factory name with the top-level factoryName property, not under parameters.')
    }
    $unknown = @($Config.Parameters.Keys | Where-Object { $_ -ne 'factoryName' -and $_ -notin @($Template.Parameters.Keys) })
    if ($unknown.Count -gt 0) {
        $errors.Add("These parameters aren't in the ARM template, so remove them: $($unknown -join ', ').")
    }
    if ($Config.IsAuthoringFactory -and $Config.FactoryName -ne $Template.SourceFactoryName) {
        $errors.Add("isAuthoringFactory is true, but the template was exported from '$($Template.SourceFactoryName)', not '$($Config.FactoryName)'. Only the factory connected to this repository can reuse the exported values.")
    }

    $entries = [ordered]@{}
    $rows = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $Template.Parameters.Keys) {
        $definition = $Template.Parameters[$name]
        $type = [string]$definition['type']
        $isSecure = $type -in 'securestring', 'secureobject'
        $hasDefault = $definition.Contains('defaultValue')

        if ($name -eq 'factoryName') {
            $entries[$name] = [ordered]@{ value = $Config.FactoryName }
            $rows.Add([pscustomobject]@{ Name = $name; Source = 'factoryName'; Value = $Config.FactoryName })
            continue
        }

        if ($Config.Parameters.ContainsKey($name)) {
            $entry = $Config.Parameters[$name]
            if ($entry.Contains('reference')) {
                $source = 'environment, Key Vault'
                $display = "secret $($entry['reference']['secretName'])"
            }
            else {
                if (-not (Test-ParameterValueType -Type $type -Value $entry['value'])) {
                    $errors.Add("Parameter $name must be a $type value.")
                }
                $source = 'environment'
                $display = $isSecure ? '(secure)' : (Format-DisplayValue $entry['value'])
            }
            $entries[$name] = $entry
            $rows.Add([pscustomobject]@{ Name = $name; Source = $source; Value = $display })
            continue
        }

        if (-not $Config.IsAuthoringFactory) {
            $hint = ($isSecure -or -not $hasDefault) ? '' : " Development value: $(Format-DisplayValue $definition['defaultValue'])"
            $missing.Add("    $name ($type).$hint")
            continue
        }
        if (-not $hasDefault) {
            $errors.Add("Parameter $name has no exported value, so set it under parameters.")
            continue
        }

        $default = $definition['defaultValue']
        if (Test-ContainsTemplateExpression $default) {
            # A parameter file can't carry template expressions, so let ARM evaluate the default.
            $source = 'template default'
        }
        else {
            $entries[$name] = [ordered]@{ value = $default }
            $source = 'exported value'
        }
        $rows.Add([pscustomobject]@{ Name = $name; Source = $source; Value = ($isSecure ? '(secure)' : (Format-DisplayValue $default)) })
    }

    if ($missing.Count -gt 0) {
        $errors.Add("Only the authoring factory may inherit the exported (development) values, so set these under parameters, each as { ""value"": ... } or a Key Vault { ""reference"": ... }:`n$($missing -join "`n")")
    }
    if ($errors.Count -gt 0) {
        throw "$($Config.DisplayPath) doesn't fit the ARM template:`n- $($errors -join "`n- ")"
    }

    [pscustomobject]@{ Entries = $entries; Rows = $rows }
}

function Write-Plan {
    param([Parameter(Mandatory)] $Template, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Plan)
    $counts = foreach ($kind in $ArtifactKinds.Keys) {
        if ($Template.Artifacts[$kind].Count -gt 0) { "$($ArtifactKinds[$kind]): $($Template.Artifacts[$kind].Count)" }
    }
    Write-Host "Environment:    $Environment ($($Config.DisplayPath))"
    Write-Host "Target factory: $($Config.FactoryName) (resource group $($Config.ResourceGroupName))"
    Write-Host "Template:       exported from $($Template.SourceFactoryName); $($counts -join ', ')"
    Write-Host 'Parameters:'
    foreach ($row in $Plan.Rows) {
        Write-Host "    $($row.Name) = $($row.Value)  [$($row.Source)]"
    }
}

function Read-BuildInfo {
    param([string] $Path)
    if (-not $Path) {
        $Path = Join-Path $ArtifactRoot 'build-info.json'
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
    }
    $info = Read-JsonFile -Path (Resolve-FullPath $Path) -Description 'Build information'
    foreach ($key in 'sourceCommit', 'workflow', 'runNumber', 'runUrl') {
        if ($info -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace("$($info[$key])")) {
            throw "Build information $Path is missing $key."
        }
    }
    $runNumber = 0L
    if (-not [long]::TryParse("$($info['runNumber'])", [ref]$runNumber) -or $runNumber -le 0) {
        throw "Build information $Path has an invalid runNumber."
    }
    [pscustomobject]@{
        SourceCommit = [string]$info['sourceCommit']
        Workflow     = [string]$info['workflow']
        RunNumber    = $runNumber
        RunUrl       = [string]$info['runUrl']
    }
}

function Write-ParameterFile {
    param([Parameter(Mandatory)] $Plan)
    $folder = $env:RUNNER_TEMP ? $env:RUNNER_TEMP : [System.IO.Path]::GetTempPath()
    $path = Join-Path $folder "adf-$Environment-parameters-$([guid]::NewGuid().ToString('N')).json"
    [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $Plan.Entries
    } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    $path
}

#endregion

#region Azure

function Import-RequiredModule {
    foreach ($module in 'Az.Accounts', 'Az.Resources', 'Az.DataFactory') {
        if (-not (Get-Module -Name $module)) {
            if (-not (Get-Module -Name $module -ListAvailable)) {
                throw "PowerShell module $module isn't installed. Run: Install-Module Az -Scope CurrentUser"
            }
            Import-Module $module -Verbose:$false
        }
    }
}

function Get-TargetFactory {
    param([Parameter(Mandatory)] $Config)
    try {
        Get-AzDataFactoryV2 -ResourceGroupName $Config.ResourceGroupName -Name $Config.FactoryName
    }
    catch {
        throw "Can't read data factory '$($Config.FactoryName)' in resource group '$($Config.ResourceGroupName)': $($_.Exception.Message) Deployments don't create factories, so create it first, and give the deployment identity the Data Factory Contributor role on it."
    }
}

function Confirm-FactoryIdentity {
    param([Parameter(Mandatory)] $Factory, [Parameter(Mandatory)] $Config, [string[]] $AttachedIdentityIds)
    $identity = $Factory.Identity
    if ($Config.SystemAssignedPrincipalId) {
        $actual = ($null -ne $identity -and "$($identity.Type)" -match 'SystemAssigned') ? "$($identity.PrincipalId)" : 'none'
        if ($actual -ne $Config.SystemAssignedPrincipalId) {
            throw "Factory '$($Config.FactoryName)' should have the system-assigned managed identity $($Config.SystemAssignedPrincipalId), but it has $actual. If the factory was recreated, grant its new identity access to the resources its linked services use, then update factoryIdentity in $($Config.DisplayPath)."
        }
    }
    foreach ($id in $Config.UserAssignedIdentityIds) {
        if ($id -notin $AttachedIdentityIds) {
            throw "User-assigned identity $id from $($Config.DisplayPath) isn't attached to factory '$($Config.FactoryName)'."
        }
    }
}

function Confirm-CredentialIdentity {
    param([Parameter(Mandatory)] $Template, [Parameter(Mandatory)] $Plan, [Parameter(Mandatory)] $Config, [string[]] $AttachedIdentityIds)
    foreach ($credential in $Template.Credentials) {
        $resourceId = Resolve-TemplateValue -Value $credential.ResourceId -Plan $Plan
        if (-not $resourceId) {
            Write-Annotation warning "Can't check which identity credential '$($credential.Name)' uses, because its resourceId is only known to ARM."
        }
        elseif ($resourceId -notin $AttachedIdentityIds) {
            throw "Credential '$($credential.Name)' uses the user-assigned identity $resourceId, which isn't attached to factory '$($Config.FactoryName)'. Attach it to the factory, or set the credential's resourceId parameter in $($Config.DisplayPath)."
        }
    }
}

function Write-GitConfigurationWarning {
    param([Parameter(Mandatory)] $Factory, [Parameter(Mandatory)] $Config)
    $repository = $Factory.RepoConfiguration
    if ($Config.IsAuthoringFactory) {
        if ($null -eq $repository) {
            Write-Annotation warning "Factory '$($Config.FactoryName)' is the authoring factory in $($Config.DisplayPath), but it isn't connected to Git."
        }
        elseif (-not $repository.DisablePublish) {
            Write-Annotation warning "ADF Studio can still publish to '$($Config.FactoryName)', which would overwrite what this workflow deployed. In ADF Studio, go to Manage > Git configuration and select Disable publish."
        }
    }
    elseif ($null -ne $repository) {
        Write-Annotation warning "Factory '$($Config.FactoryName)' is connected to Git. Only the authoring factory should be; deployments only update the live mode of the others."
    }
}

function Confirm-NewestBuild {
    # Stops an old run (a late approval, or a re-run) from replacing a newer build of this workflow.
    param([Parameter(Mandatory)] $Config, $BuildInfo)
    if ($null -eq $BuildInfo) {
        Write-Host 'No build information, so skipping the check for newer deployed builds.'
        return
    }
    $prefix = "adf-cicd-$Environment-r"
    $newer = @(
        Get-AzResourceGroupDeployment -ResourceGroupName $Config.ResourceGroupName | Where-Object {
            $runNumber = 0L
            $_.DeploymentName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.ProvisioningState -eq 'Succeeded' -and
            $null -ne $_.Tags -and
            $_.Tags['adfBuildWorkflow'] -eq $BuildInfo.Workflow -and
            $_.Tags['adfFactory'] -eq $Config.FactoryName -and
            [long]::TryParse("$($_.Tags['adfBuildRunNumber'])", [ref]$runNumber) -and
            $runNumber -gt $BuildInfo.RunNumber
        }
    )
    if ($newer.Count -gt 0) {
        $latest = $newer | Sort-Object { [long]$_.Tags['adfBuildRunNumber'] } -Descending | Select-Object -First 1
        throw "Run $($latest.Tags['adfBuildRunNumber']) of this workflow already deployed a newer build to '$($Config.FactoryName)' (deployment $($latest.DeploymentName)), so this run ($($BuildInfo.RunNumber)) won't replace it with an older one. To roll back, revert the change in the collaboration branch and let the new run deploy it."
    }
}

function Get-LiveState {
    param([Parameter(Mandatory)] [hashtable] $FactoryArgs)
    $triggers = @(Get-AzDataFactoryV2Trigger @FactoryArgs)
    $names = [ordered]@{
        triggers            = @($triggers | ForEach-Object Name)
        pipelines           = @(Get-AzDataFactoryV2Pipeline @FactoryArgs | ForEach-Object Name)
        dataflows           = @(Get-AzDataFactoryV2DataFlow @FactoryArgs | ForEach-Object Name)
        datasets            = @(Get-AzDataFactoryV2Dataset @FactoryArgs | ForEach-Object Name)
        linkedServices      = @(Get-AzDataFactoryV2LinkedService @FactoryArgs | ForEach-Object Name)
        integrationRuntimes = @(Get-AzDataFactoryV2IntegrationRuntime @FactoryArgs | ForEach-Object Name)
    }
    $triggerStates = @{}
    foreach ($trigger in $triggers) {
        $triggerStates[$trigger.Name] = "$($trigger.RuntimeState)"
    }
    [pscustomobject]@{ Names = $names; TriggerStates = $triggerStates }
}

function Get-PendingDeletion {
    param([Parameter(Mandatory)] $Template, [Parameter(Mandatory)] $Live)
    $deletions = [ordered]@{}
    foreach ($kind in $ArtifactKinds.Keys) {
        $names = @(Get-NameDifference -From $Live.Names[$kind] -In $Template.Artifacts[$kind])
        if ($names.Count -gt 0) {
            $deletions[$kind] = $names
        }
    }
    $deletions
}

function Invoke-PrePostDeploymentScript {
    param(
        [Parameter(Mandatory)] $Template,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ParameterFile,
        [Parameter(Mandatory)] [bool] $PreDeployment
    )
    $arguments = @{
        ArmTemplate           = $Template.TemplatePath
        ArmTemplateParameters = $ParameterFile
        ResourceGroupName     = $Config.ResourceGroupName
        DataFactoryName       = $Config.FactoryName
        PreDeployment         = $PreDeployment
        # Its clean-up only recognizes deployments named ArmTemplate_master* or ArmTemplateForFactory*.
        # This script's deployments stay in the history for Confirm-NewestBuild; ARM prunes old
        # history entries automatically.
        DeleteDeployment      = $false
    }
    # Microsoft's script isn't written for strict mode.
    & { Set-StrictMode -Off; & $Template.PrePostScriptPath @arguments }
}

function Write-DeploymentSummary {
    param(
        [Parameter(Mandatory)] $Template,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Deletions,
        [Parameter(Mandatory)] [string] $DeploymentName,
        $BuildInfo
    )
    if (-not $env:GITHUB_STEP_SUMMARY) {
        return
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("### Data Factory deployment: $Environment")
    $lines.Add('')
    $lines.Add('| | |')
    $lines.Add('|---|---|')
    $lines.Add("| Factory | ``$($Config.FactoryName)`` (resource group ``$($Config.ResourceGroupName)``) |")
    $lines.Add("| ARM deployment | ``$DeploymentName`` |")
    if ($null -ne $BuildInfo) {
        $lines.Add("| Source commit | ``$($BuildInfo.SourceCommit)`` |")
    }
    $lines.Add('')
    $lines.Add('| Artifact type | Deployed | Deleted |')
    $lines.Add('|---|---|---|')
    foreach ($kind in $ArtifactKinds.Keys) {
        $deleted = $Deletions.Contains($kind) ? ($Deletions[$kind] -join ', ') : ''
        $lines.Add("| $($ArtifactKinds[$kind]) | $($Template.Artifacts[$kind].Count) | $deleted |")
    }
    $lines.Add('')
    $lines.Add('| Parameter | Value from |')
    $lines.Add('|---|---|')
    foreach ($row in $Plan.Rows) {
        $lines.Add("| ``$($row.Name)`` | $($row.Source) |")
    }
    $lines.Add('')
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $lines -Encoding utf8NoBOM
}

#endregion

try {
    if ($CheckConfigurationOnly -and $ValidateOnly) {
        throw 'Use -CheckConfigurationOnly or -ValidateOnly, not both.'
    }

    $template = Read-ArmTemplate -Folder (Resolve-TemplateFolder -Folder $ArmTemplateFolder)
    $config = Read-EnvironmentConfig -Path (Join-Path (Resolve-FullPath $EnvironmentConfigFolder) "$Environment.json")
    $plan = Get-ParameterPlan -Template $template -Config $config
    Write-Plan -Template $template -Config $config -Plan $plan

    if ($CheckConfigurationOnly) {
        Write-Host "The configuration for '$Environment' fits the template."
        return
    }

    $buildInfo = Read-BuildInfo -Path $BuildInfoPath
    if ($null -ne $buildInfo) {
        Write-Host "Build:          commit $($buildInfo.SourceCommit), run $($buildInfo.RunNumber) ($($buildInfo.RunUrl))"
    }
    Import-RequiredModule
    $context = Get-AzContext
    if ($null -eq $context -or $null -eq $context.Account) {
        throw 'Not signed in to Azure. Run Connect-AzAccount first.'
    }
    Write-Host "Signed in as $($context.Account.Id), subscription '$($context.Subscription.Name)'."

    $factory = Get-TargetFactory -Config $config
    $attachedIdentityIds = @(
        if ($null -ne $factory.Identity -and $null -ne $factory.Identity.UserAssignedIdentities) {
            $factory.Identity.UserAssignedIdentities.Keys
        }
    )
    Confirm-FactoryIdentity -Factory $factory -Config $config -AttachedIdentityIds $attachedIdentityIds
    Confirm-CredentialIdentity -Template $template -Plan $plan -Config $config -AttachedIdentityIds $attachedIdentityIds
    Write-GitConfigurationWarning -Factory $factory -Config $config
    Confirm-NewestBuild -Config $config -BuildInfo $buildInfo

    $factoryArgs = @{ ResourceGroupName = $config.ResourceGroupName; DataFactoryName = $config.FactoryName }
    $before = Get-LiveState -FactoryArgs $factoryArgs
    $deletions = Get-PendingDeletion -Template $template -Live $before
    if ($deletions.Count -gt 0) {
        $list = foreach ($kind in $deletions.Keys) { "$($ArtifactKinds[$kind]): $($deletions[$kind] -join ', ')" }
        Write-Annotation warning "The post-deployment step will delete these artifacts from '$($config.FactoryName)' because they aren't in the template:`n$($list -join "`n")"
    }
    else {
        Write-Host 'No artifacts will be deleted.'
    }

    $parameterFile = Write-ParameterFile -Plan $plan
    try {
        $deploymentArgs = @{
            ResourceGroupName           = $config.ResourceGroupName
            Mode                        = 'Incremental'
            TemplateFile                = $template.TemplatePath
            TemplateParameterFile       = $parameterFile
            SkipTemplateParameterPrompt = $true
        }

        if ($ValidateOnly) {
            $validationErrors = @(Test-AzResourceGroupDeployment @deploymentArgs)
            if ($validationErrors.Count -gt 0) {
                $messages = foreach ($validationError in $validationErrors) {
                    "$($validationError.Code): $($validationError.Message)"
                    foreach ($detail in @($validationError.Details)) {
                        if ($null -ne $detail) { "    $($detail.Code): $($detail.Message)" }
                    }
                }
                throw "ARM validation failed:`n$($messages -join "`n")"
            }
            Invoke-LogGroup 'What-if' { Get-AzResourceGroupDeploymentWhatIfResult @deploymentArgs -ResultFormat ResourceIdOnly }
            Write-Host "Validation passed for '$Environment'. Nothing was changed."
            return
        }

        $deploymentName = if ($null -ne $buildInfo -and $InGitHubActions) {
            "adf-cicd-$Environment-r$($buildInfo.RunNumber)-a$($env:GITHUB_RUN_ATTEMPT ? $env:GITHUB_RUN_ATTEMPT : '1')"
        }
        else {
            "adf-cicd-$Environment-local-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
        }
        $tags = @{ adfEnvironment = $Environment; adfFactory = $config.FactoryName }
        if ($null -ne $buildInfo) {
            $tags['adfSourceCommit'] = $buildInfo.SourceCommit
            $tags['adfBuildWorkflow'] = $buildInfo.Workflow
            $tags['adfBuildRunNumber'] = "$($buildInfo.RunNumber)"
            $tags['adfBuildRunUrl'] = $buildInfo.RunUrl
        }

        try {
            Invoke-LogGroup 'Pre-deployment: stop triggers that will change' {
                Invoke-PrePostDeploymentScript -Template $template -Config $config -ParameterFile $parameterFile -PreDeployment $true
            }

            Write-Host "Deploying to '$($config.FactoryName)' as ARM deployment $deploymentName..."
            $deployment = New-AzResourceGroupDeployment @deploymentArgs -Name $deploymentName -Tag $tags
            if ($deployment.ProvisioningState -ne 'Succeeded') {
                throw "ARM deployment $deploymentName finished as $($deployment.ProvisioningState)."
            }

            Invoke-LogGroup 'Post-deployment: delete removed artifacts and start triggers' {
                Invoke-PrePostDeploymentScript -Template $template -Config $config -ParameterFile $parameterFile -PreDeployment $false
            }
        }
        catch {
            # The pre-deployment step may have stopped triggers that a failure leaves stopped.
            try {
                $now = Get-LiveState -FactoryArgs $factoryArgs
                $stopped = @($before.TriggerStates.Keys | Where-Object { $before.TriggerStates[$_] -eq 'Started' -and $now.TriggerStates[$_] -ne 'Started' })
                if ($stopped.Count -gt 0) {
                    Write-Annotation warning "These triggers were running before the deployment and are stopped now: $($stopped -join ', '). Fix the failure and re-run the deployment; its post-deployment step starts the triggers that the template marks as Started."
                }
            }
            catch {
                Write-Annotation warning "Couldn't check the trigger states after the failure: $($_.Exception.Message)"
            }
            throw
        }

        $after = Get-LiveState -FactoryArgs $factoryArgs
        $mismatches = foreach ($kind in $ArtifactKinds.Keys) {
            $notDeployed = @(Get-NameDifference -From $template.Artifacts[$kind] -In $after.Names[$kind])
            $notDeleted = @(Get-NameDifference -From $after.Names[$kind] -In $template.Artifacts[$kind])
            if ($notDeployed.Count -gt 0) { "$($ArtifactKinds[$kind]) missing from the factory: $($notDeployed -join ', ')" }
            if ($notDeleted.Count -gt 0) { "$($ArtifactKinds[$kind]) still in the factory but not in the template: $($notDeleted -join ', ')" }
        }
        if ($mismatches) {
            throw "After the deployment, factory '$($config.FactoryName)' doesn't match the template:`n$($mismatches -join "`n")"
        }
        foreach ($trigger in $template.TriggerStates.Keys) {
            $expected = Resolve-TemplateValue -Value $template.TriggerStates[$trigger] -Plan $plan
            $actual = $after.TriggerStates[$trigger]
            if ($expected -and $actual -and $actual -ne $expected) {
                Write-Annotation warning "Trigger '$trigger' is $actual in '$($config.FactoryName)', but the template sets it to $expected."
            }
        }

        Write-DeploymentSummary -Template $template -Config $config -Plan $plan -Deletions $deletions -DeploymentName $deploymentName -BuildInfo $buildInfo
        Write-Host "Deployed to '$($config.FactoryName)' and checked its artifacts against the template."
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    }
}
catch {
    if ($InGitHubActions) {
        Write-Annotation error $_.Exception.Message
    }
    throw
}
