# Data Factory source for the GraphQL → Azure SQL sync

This repository is the Git source of the `nyc-dohmh-adf-graphql-to-sql` data factory. ADF Studio saves the factory's artifacts here (`factory/`, `linkedService/`, `dataset/`, `pipeline/`), and GitHub Actions deploys them to the dev and prd factories.

The deployment follows [the new CI/CD flow](https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-improvements) for Azure Data Factory. Nobody selects **Publish** in ADF Studio. Instead, a build validates the artifacts in the `collab` branch and exports them as an ARM template with the [`@microsoft/azure-data-factory-utilities`](https://www.npmjs.com/package/@microsoft/azure-data-factory-utilities) npm package. That one template is then deployed to dev and, after approval, to prd, each with its own values.

The pipeline itself is described in the [sample repository](https://github.com/fmushinsky-at-msft/adf-graphql-to-sql).

## Environments

| | dev | prd |
|---|---|---|
| Data factory | `nyc-dohmh-adf-graphql-to-sql`, connected to this repository | `nyc-dohmh-adf-graphql-to-sql-prd`, not connected to Git |
| Destination database | `nyc-dohmh-adf-graphql-to-sql-2` | `nyc-dohmh-adf-graphql-to-sql-prd-2` |
| GraphQL API | `https://nyc-dohmh-adf-graphql-to-sql-fuhnhxaxgzgyfqbq.canadacentral-01.azurewebsites.net/graphql` | Same API |
| GitHub environment | `dev` | `prd`, with required reviewers |
| Deployment identity | `nyc-dohmh-adf-graphql-to-sql-gh-deploy` | `nyc-dohmh-adf-graphql-to-sql-prd-gh-deploy` |
| Configuration | [`deploy/environments/dev.json`](deploy/environments/dev.json) | [`deploy/environments/prd.json`](deploy/environments/prd.json) |

Everything is in resource group `nyc-dohmh-adf-graphql-to-sql`. Both databases are on SQL server `nyc-dohmh-adf-graphql-to-sql`.

## How it works

```text
pull request to collab:  build
push to collab:          build ──► deploy-dev ──► approval ──► deploy-prd
                           │            │                           │
              validate and export   dev factory                prd factory
              the ARM template once
```

| Run | build | deploy-dev | deploy-prd |
|---|:---:|:---:|:---:|
| Pull request to `collab` | ✓ | | |
| Push to `collab` (a merge, or a save in ADF Studio) | ✓ | ✓ | ✓ after approval |
| **Run workflow** on `collab` | ✓ | ✓ | ✓ after approval |
| **Run workflow** on another branch | ✓ | | |

Changes to Markdown files alone don't start a run.

**build** ([`adf-ci-cd.yml`](.github/workflows/adf-ci-cd.yml))

1. Installs the pinned Data Factory utilities with `npm ci`.
2. Runs their `export` command, which validates every artifact (like **Validate all** in ADF Studio) and writes the ARM template. The command needs a factory resource ID but only uses the factory name from it, so the build passes a placeholder ID.
3. Checks every `deploy/environments/*.json` against the template. A pull request that adds a parameter without giving prd a value fails here, before it's merged.
4. Uploads the template, the `deploy` folder and `build-info.json` (commit, run, tool versions) as the `ArmTemplates` artifact.

**deploy-dev**, **deploy-prd** ([`adf-deploy.yml`](.github/workflows/adf-deploy.yml), one at a time per environment)

1. Runs in the GitHub environment of the same name, so deploy-prd waits for a required reviewer to approve it. The job then checks the environment's protection rules: deploy-prd fails without deploying if `prd` has no required reviewers, because GitHub creates a missing environment without protection rules the first time a job uses it.
2. Downloads the run's `ArmTemplates` artifact, so prd gets exactly the template that dev got.
3. Signs in to Azure with OpenID Connect as the environment's deployment identity. No Azure credential is stored in GitHub.
4. Runs [`deploy/Deploy-AdfArtifacts.ps1`](deploy/Deploy-AdfArtifacts.ps1), which:
   - merges `deploy/environments/<env>.json` over the template's parameters;
   - checks that the factory exists and has the expected managed identity;
   - refuses to deploy a build older than the last one this workflow deployed to that factory (see [Rolling back and re-running](#rolling-back-and-re-running));
   - lists any artifacts that the deployment will delete, before changing anything;
   - runs the exported `PrePostDeploymentScript.ps1` to stop triggers that will change, deploys the template in Incremental mode, then runs the script again to delete artifacts that are no longer in the template and to start triggers;
   - checks that the factory now has exactly the template's artifacts, and writes the job summary.

The template never contains the factory resource itself, so deployments don't change a factory's Git configuration, managed identity, networking or encryption.

## Repository layout

| Path | Contents |
|---|---|
| `factory/`, `linkedService/`, `dataset/`, `pipeline/` | The Data Factory artifacts. Edit them in ADF Studio. |
| `publish_config.json` | Data Factory settings. `includeGlobalParamsTemplate` adds global parameters to the exported template. |
| `arm-template-parameters-definition.json` | Which artifact properties become template parameters, so that each environment can set them ([custom parameters](https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-resource-manager-custom-parameters)). |
| `build/package.json`, `build/package-lock.json` | Pin the Data Factory utilities that the build uses. |
| `deploy/Deploy-AdfArtifacts.ps1` | Deploys the exported template to one environment. |
| `deploy/environments/` | One configuration file per environment. |
| `.github/workflows/adf-ci-cd.yml` | The workflow: build, deploy-dev, deploy-prd. |
| `.github/workflows/adf-deploy.yml` | The deployment job, called once per environment. |

ADF Studio ignores files and folders that aren't Data Factory artifacts.

## One-time setup

### Azure (done)

Each environment has its own deployment identity: a user-assigned managed identity that GitHub signs in as through a federated credential. Each identity can deploy only to its own factory.

| | dev | prd |
|---|---|---|
| Identity | `nyc-dohmh-adf-graphql-to-sql-gh-deploy` | `nyc-dohmh-adf-graphql-to-sql-prd-gh-deploy` |
| Client ID | `3e35c3fb-14ae-46d1-b91a-aa9da0da1569` | `fd64e02c-6cd8-4adb-9e52-d8206e26b3fa` |
| Federated credential subject | `repo:fmushinsky-at-msft@223750856/adf-graphql-to-sql-adf-source@1410607182:environment:dev` | `repo:fmushinsky-at-msft@223750856/adf-graphql-to-sql-adf-source@1410607182:environment:prd` |
| Data Factory Contributor on | The dev factory | The prd factory |

Both identities also have the custom role **ARM Template Deployment Operator (nyc-dohmh-adf-graphql-to-sql)** on the resource group. It allows `Microsoft.Resources/deployments/*` and `Microsoft.Resources/subscriptions/resourceGroups/read`: enough to run a template deployment, but no rights on any resource. ARM checks the identity's rights on every resource in the template, and each identity only has rights on its own factory.

The subjects contain GitHub's owner and repository IDs because this repository was created after 15 July 2026, so it uses [immutable subject claims](https://docs.github.com/actions/reference/security/oidc#immutable-subject-claims). Older repositories use `repo:<owner>/<repository>:environment:<environment>`.

Each factory's own system-assigned managed identity needs access to its destination database. In the sample repository, `sql/04-dest-grant-adf-sami.sql` (dev) and `sql/04-dest-grant-adf-sami-prd.sql` (prd) grant it.

<details>
<summary>Azure CLI commands to create an environment's deployment identity</summary>

```bash
rg=nyc-dohmh-adf-graphql-to-sql
env=prd
factory=nyc-dohmh-adf-graphql-to-sql-prd
identity=$factory-gh-deploy
rg_id=$(az group show -n $rg --query id -o tsv)

# The custom role, once per resource group. It can take a minute before it can be assigned.
cat > role.json <<EOF
{
  "Name": "ARM Template Deployment Operator ($rg)",
  "Description": "Create, validate and monitor ARM template deployments in the resource group.",
  "Actions": ["Microsoft.Resources/deployments/*", "Microsoft.Resources/subscriptions/resourceGroups/read"],
  "AssignableScopes": ["$rg_id"]
}
EOF
az role definition create --role-definition @role.json

az identity create -g $rg -n $identity
az identity federated-credential create -g $rg --identity-name $identity -n gh-adf-source-env-$env \
  --issuer https://token.actions.githubusercontent.com --audiences api://AzureADTokenExchange \
  --subject "repo:fmushinsky-at-msft@223750856/adf-graphql-to-sql-adf-source@1410607182:environment:$env"

principal=$(az identity show -g $rg -n $identity --query principalId -o tsv)
factory_id=$(az resource show -g $rg -n $factory --resource-type Microsoft.DataFactory/factories --query id -o tsv)
az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal \
  --role "Data Factory Contributor" --scope $factory_id
az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal \
  --role "ARM Template Deployment Operator ($rg)" --scope $rg_id
```

</details>

### GitHub (to do)

1. In **Settings → Environments**, create the environments `dev` and `prd`.
2. In `prd`, select **Required reviewers** and add the people who approve production deployments. If you're the only maintainer, leave **Prevent self-review** off, or nobody can approve.
3. In both environments, under **Deployment branches and tags**, select **Selected branches and tags** and add the branch `collab`.
4. In each environment, add these environment secrets:

   | Secret | dev | prd |
   |---|---|---|
   | `AZURE_CLIENT_ID` | `3e35c3fb-14ae-46d1-b91a-aa9da0da1569` | `fd64e02c-6cd8-4adb-9e52-d8206e26b3fa` |
   | `AZURE_TENANT_ID` | `9ca5774b-4503-4f6f-8c87-1ad4a09e20d4` | `9ca5774b-4503-4f6f-8c87-1ad4a09e20d4` |
   | `AZURE_SUBSCRIPTION_ID` | `19c0c420-bf90-4cb3-80cf-6479a48dd6a3` | `19c0c420-bf90-4cb3-80cf-6479a48dd6a3` |

   These are identifiers, not credentials. As environment secrets, they're only given to jobs that passed the environment's protection rules, and each environment keeps its own identity.

5. Recommended:
   - Make `collab` the default branch (**Settings → General**). GitHub only shows the **Run workflow** button for workflows in the default branch.
   - Protect `collab` with a branch ruleset that requires a pull request and the **Validate and export ARM template** status check. ADF Studio users then save their work in feature branches and create pull requests from ADF Studio.

Steps 1 to 4 with the GitHub CLI, as a repository administrator (Bash):

```bash
repo=fmushinsky-at-msft/adf-graphql-to-sql-adf-source
me=$(gh api user --jq .id)
branch_policy='"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}'
gh api -X PUT repos/$repo/environments/dev --input - <<< "{$branch_policy}"
gh api -X PUT repos/$repo/environments/prd --input - <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":$me}],$branch_policy}"
for env in dev prd; do
  gh api -X POST repos/$repo/environments/$env/deployment-branch-policies -f name=collab -f type=branch
  gh secret set AZURE_TENANT_ID --repo $repo --env $env --body 9ca5774b-4503-4f6f-8c87-1ad4a09e20d4
  gh secret set AZURE_SUBSCRIPTION_ID --repo $repo --env $env --body 19c0c420-bf90-4cb3-80cf-6479a48dd6a3
done
gh secret set AZURE_CLIENT_ID --repo $repo --env dev --body 3e35c3fb-14ae-46d1-b91a-aa9da0da1569
gh secret set AZURE_CLIENT_ID --repo $repo --env prd --body fd64e02c-6cd8-4adb-9e52-d8206e26b3fa
```

### ADF Studio (to do, once the workflow has deployed)

In the dev factory, open **Manage → Git configuration → Edit**, select **Disable publish (from ADF Studio)**, and apply. Otherwise, publishing from ADF Studio overwrites what the workflow deployed to the dev factory. Until you do, every dev deployment warns about it. The `adf_publish` branch is no longer used.

## Making a change

1. In ADF Studio (dev factory), switch to a feature branch, make the change and save it. Test it with **Debug**.
2. Create a pull request to `collab`. The build validates the factory and checks the environment configurations.
3. Merge it. The workflow deploys to dev. The run's summary shows each parameter's value and where it came from, and anything that was deleted.
4. A prd reviewer opens the run and selects **Review deployments**, then **Approve and deploy**.

## Environment configuration

Each `deploy/environments/<env>.json` file looks like this (the comments are only for this example):

```jsonc
{
  "description": "Production.",
  "resourceGroupName": "nyc-dohmh-adf-graphql-to-sql",
  "factoryName": "nyc-dohmh-adf-graphql-to-sql-prd",   // also sets the factoryName template parameter
  "isAuthoringFactory": false,                          // true only for the factory connected to this repository
  "factoryIdentity": {                                  // optional, checked before deploying
    "systemAssignedPrincipalId": "<object ID>",         // the factory's system-assigned managed identity
    "userAssignedIdentityIds": ["<resource ID>"]        // identities that must be attached to the factory
  },
  "parameters": {
    "<template parameter>": { "value": "..." }
  }
}
```

- The authoring factory, dev, uses the exported values for any parameter that its file doesn't set: they're its own values.
- Every other environment must set **every** template parameter, so a development value can't reach production by omission. Otherwise the build fails and lists the missing parameters with their development values.
- A parameter that isn't in the template, or a value of the wrong type, also fails the build.
- `factoryIdentity` catches a recreated factory, whose new managed identity has no database access yet.

`prd.json` sets these parameters:

| Parameter | What it sets | prd value |
|---|---|---|
| `LS_DestinationSql_connectionString` | The `LS_DestinationSql` connection string | Database `nyc-dohmh-adf-graphql-to-sql-prd-2` |
| `LS_GraphQlApi_properties_typeProperties_url` | The `LS_GraphQlApi` URL | The GraphQL API |
| `PL_Sync_Restaurants_GraphQL_To_Sql_graphQlEndpoint` | The default value of the pipeline's `graphQlEndpoint` parameter | The GraphQL API |

### Parameterizing another property

1. If the property isn't a template parameter yet, add a rule to `arm-template-parameters-definition.json`. In ADF Studio, that's **Manage → ARM template → Edit parameter configuration**. See [custom parameters](https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-resource-manager-custom-parameters).
2. Create a pull request. The build fails and names the new parameter, because `prd.json` doesn't set it.
3. Add the parameter's prd value to `prd.json` in the same pull request.

### Triggers and global parameters

- Each trigger's state becomes the parameter `<trigger>_properties_runtimeState` (`Started` or `Stopped`), so prd can run a schedule that dev keeps stopped. Deployments stop the triggers that change, then start the ones set to `Started`.
- Global parameters are deployed with the template, each as the parameter `default_properties_<global parameter>_value`.

There are no triggers or global parameters yet. When you add some, the build tells you which parameters to add to `prd.json`.

### Secrets

The factory has no secrets: it connects with managed identities. If a linked service ever needs a secret, prefer an Azure Key Vault linked service, so that the factory reads the secret when it runs and only the vault URL differs per environment. To pass a secret as a template parameter instead, reference it from Key Vault:

```json
"LS_Example_password": {
  "reference": {
    "keyVault": { "id": "/subscriptions/<subscription>/resourceGroups/<group>/providers/Microsoft.KeyVault/vaults/<vault>" },
    "secretName": "<secret>"
  }
}
```

The vault must allow Azure Resource Manager template deployment, and the deployment identity needs the `Microsoft.KeyVault/vaults/deploy/action` permission on it.

## Rolling back and re-running

- **Roll back** by reverting the change in `collab` through a pull request. The new run deploys the reverted artifacts to dev, then to prd.
- **An older run can't overwrite a newer one.** Each deployment is an ARM deployment in the resource group, named `adf-cicd-<env>-r<run number>-a<attempt>` and tagged with the commit and run. A run stops without changing anything if a newer run already deployed to that factory, for example when an old prd deployment is approved late or an old run is re-run.
- **Re-run failed jobs** reuses the run's artifact, so a failed prd deployment retries exactly the template that was approved. **Re-run all jobs** builds the same commit again.

## Running locally

You need Node.js 22, which the build uses (the Data Factory utilities support only versions 20 and 22), and PowerShell 7.5 or later with the Az modules.

```powershell
# Validate the artifacts and export the ARM template to build/ArmTemplate.
cd build
npm ci --ignore-scripts
npm run build -- export (Resolve-Path ..).Path /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/adf-build/providers/Microsoft.DataFactory/factories/nyc-dohmh-adf-graphql-to-sql ArmTemplate
cd ..

# Check an environment's configuration against the template, offline.
./deploy/Deploy-AdfArtifacts.ps1 -Environment prd -CheckConfigurationOnly

# Run every check against Azure and preview the changes, without changing anything.
Connect-AzAccount -Tenant 9ca5774b-4503-4f6f-8c87-1ad4a09e20d4 -Subscription 19c0c420-bf90-4cb3-80cf-6479a48dd6a3
./deploy/Deploy-AdfArtifacts.ps1 -Environment prd -ValidateOnly
```

- Give `export` a relative output folder. It treats the output folder as relative to the current folder even when it's an absolute path, and still reports success.
- In Git Bash, set `MSYS_NO_PATHCONV=1` first. Otherwise Git Bash turns the `/subscriptions/...` argument into a Windows path.
- Deploy through the workflow, not from your computer. A local deployment isn't linked to a build, so the older-run check can't protect it.

## Things to know

- **Deletions.** A deployment deletes every trigger, pipeline, data flow, dataset, linked service and integration runtime in the factory that isn't in the template, including ones created by hand in the prd factory. The job log lists them before the deployment starts.
- **Order.** Deployments to an environment run one at a time. At most one more waits its turn, and a newer run replaces it.
- **Template limits.** ARM templates are limited to 4 MB and 256 parameters. The workflow deploys `ARMTemplateForFactory.json`. A factory that outgrows these limits needs the exported linked templates instead, which are deployed from a storage account.
- **Export engine.** `build/package-lock.json` pins the utilities (1.0.3), but they download their export engine from `adf.azure.com` each time they run. The build records the engine's SHA-256 hash in `build-info.json`, so a change in the engine can be traced.

## Troubleshooting

| Message | What to do |
|---|---|
| `AADSTS700213: No matching federated identity record found for presented assertion subject '...'` | The subject in the message must match the identity's federated credential. Check the environment name and the [subject format](#azure-done). |
| `The prd environment has no required reviewers, ...` | Add required reviewers to `prd` ([GitHub setup](#github-to-do), step 2), then re-run the job. |
| `Add these secrets to the <env> environment ...` | Add the secrets ([GitHub setup](#github-to-do), step 4), then re-run the job. |
| `<env>.json doesn't fit the ARM template` | Set the listed parameters in that file. |
| `Run <n> of this workflow already deployed a newer build ...` | Expected for an old run. To roll back, revert the change in `collab`. |
| `Factory '...' should have the system-assigned managed identity ...` | The factory was recreated. Grant its new identity access to the database, then update `factoryIdentity`. |
| `ADF Studio can still publish to '...'` (warning) | [Disable publish](#adf-studio-to-do-once-the-workflow-has-deployed) in ADF Studio. |
| A re-run can't download the artifact: `(404) Not Found: workflow run not found` | A GitHub-side problem, seen in July 2026 ([actions/download-artifact#486](https://github.com/actions/download-artifact/issues/486)). Select **Re-run all jobs**. |
