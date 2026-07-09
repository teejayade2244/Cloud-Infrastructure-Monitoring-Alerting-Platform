# Terraform CI/CD Pipeline

`terraform.yml` plans and applies the Terraform project at `infra/` whenever it changes. It
authenticates to Azure via **OIDC / workload identity federation** (no client secret in GitHub),
and runs on a **self-hosted runner VM inside the VNet** (`infra/modules/runner/`) so it can reach
Key Vault and Cosmos DB through their private endpoints without any public firewall exception.

## One-time setup: Federated Credential on the service principal

OIDC needs the Azure AD app registration to trust GitHub's OIDC tokens for this specific repo.
This is managed **manually** via `az cli`, not by Terraform - an earlier version of this project
had Terraform manage it (`modules/oidc/`), but the service principal doesn't have Graph API
permissions to read or write its own app registration (`data.azuread_*` lookups fail with a 403),
and granting those permissions requires a higher-privileged Azure AD role than this project
otherwise needs. The credentials already exist in Azure from that earlier setup and don't need
to be recreated - this is here for reference / in case they ever need to be rebuilt from scratch.

```bash
# App registration's object ID (different from the client ID / app ID)
az ad app show --id 3abb3608-c205-4047-80d5-c9407c8da8da --query id -o tsv
# -> c7c82d2a-2fde-4fe8-8deb-255ad11e83f0

az ad app federated-credential create \
  --id c7c82d2a-2fde-4fe8-8deb-255ad11e83f0 \
  --parameters '{
    "name": "inframonitor-github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:teejayade2244/Cloud-Infrastructure-Monitoring-Alerting-Platform:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

az ad app federated-credential create \
  --id c7c82d2a-2fde-4fe8-8deb-255ad11e83f0 \
  --parameters '{
    "name": "inframonitor-github-actions-pr",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:teejayade2244/Cloud-Infrastructure-Monitoring-Alerting-Platform:pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# Verify what's currently configured:
az ad app federated-credential list --id c7c82d2a-2fde-4fe8-8deb-255ad11e83f0 -o table
```

If you ever rename the repo, move it to another org, or change which branch triggers apply, the
`subject` on these credentials has to be updated to match (delete and recreate, or use
`az ad app federated-credential update`) - a mismatched subject fails `azure/login@v2` with an
AADSTS70021 error, not something obviously about federated credentials.

## Required GitHub Secrets

Configure these under **Settings → Secrets and variables → Actions → Secrets tab**:

| Secret | Value |
|---|---|
| `ARM_CLIENT_ID` | Service principal / app registration client ID |
| `ARM_TENANT_ID` | Azure AD tenant ID |
| `ARM_SUBSCRIPTION_ID` | Azure subscription ID |
| `TF_VAR_current_user_object_id` | Azure AD object ID of the human operator, granted Key Vault Secrets Officer access |

No client secret is needed anywhere - `azure/login@v2` and the Terraform azurerm provider both
authenticate via the federated credential above, using the short-lived OIDC token GitHub issues
per workflow run.

## Required GitHub repository Variables

Configure these under **Settings → Secrets and variables → Actions → Variables tab** (not secrets
- these aren't sensitive):

| Variable | Value |
|---|---|
| `TF_VAR_PUBLISHER_EMAIL` | `teejay4125@outlook.com` |
| `TF_VAR_ENVIRONMENT` | `dev` |
| `TF_VAR_LOCATION` | `uksouth` |
| `TF_VAR_PROJECT` | `inframonitor` |
| `TF_VAR_CREATE_APIM` | `true` |
| `TF_VAR_CREATE_FRONTDOOR` | `true` |
| `TF_VAR_KEYVAULT_ALLOWED_IP_RANGES` | `[]` |
| `TF_VAR_COSMOS_ALLOWED_IP_RANGES` | `[]` |

`TF_VAR_CREATE_APIM`/`TF_VAR_CREATE_FRONTDOOR` gate a Developer-tier APIM instance and Front Door
- both cost money and APIM is slow to provision (30-60+ min). The workflow falls back to `true`
if either Variable is entirely unset, but if one is explicitly set to the literal text `false`
(e.g. left over from before Front Door existed, when APIM defaulted off), that value passes
through as-is - the fallback only triggers on a missing/empty Variable, not an explicit `false`.

The last two are empty lists now - the self-hosted runner reaches Key Vault/Cosmos DB via their
private endpoints, so no public IP allowlist entry is needed for CI. They still exist as
variables (rather than being deleted) in case you ever need to temporarily allow a different
public IP without touching code.

## How the pipeline works

1. **`terraform-plan`** runs on every push to `main`, every pull request touching `infra/**`, and
   on manual trigger. It logs into Azure via OIDC, runs `init` → `fmt -check` (non-blocking) →
   `validate` → `plan`, saves the plan as an artifact (`tfplan`, 5-day retention), and - on pull
   requests only - posts the plan output as a PR comment.
2. **`terraform-apply`** runs only when the ref is `main` (a push to `main`, or a manual
   `workflow_dispatch` run targeting `main`) - **never on a pull request** - and runs
   **automatically** once `terraform-plan` succeeds, with no manual approval step. It downloads
   the exact plan artifact `terraform-plan` produced in the same workflow run and applies *that
   specific plan* (`terraform apply tfplan`) rather than re-planning, so what gets applied is
   exactly what was reviewed.

## How to trigger a manual apply

- Go to **Actions → Terraform - InfraMonitor → Run workflow**, choose the `main` branch, and run
  it. This triggers both jobs; since there's no approval gate, `terraform-apply` runs immediately
  after `terraform-plan` succeeds.
- Alternatively, just push a change to `infra/**` on `main` - the same thing happens
  automatically.
- There's no way to run *only* apply without a matching plan from the same run - that's
  intentional, so you can't apply a plan you haven't seen.

## How to add a new environment (e.g. staging, prod)

This workflow and `infra/terraform.tfvars` are wired for a single `dev` environment. To add
another:

1. Give the new environment its own backend state key (in `infra/backend.tf`, or via
   `-backend-config` at init time) so it doesn't share state with `dev` - e.g.
   `key = "inframonitor-staging.tfstate"`.
2. Add a second set of `TF_VAR_*` repository variables (or use a GitHub *environment* per
   Terraform environment, which supports its own scoped variables/secrets) for the new
   environment's values.
3. Duplicate the two jobs in `terraform.yml` (or parameterize them with a matrix/input), pointing
   at the new state key and variable set.
4. If the new environment needs different Azure credentials, add a new federated credential
   (matching the new subject) and a new set of `ARM_*` secrets rather than overloading the
   existing ones - don't reuse one service principal's federated trust across environments with
   different blast radii.

## Self-hosted runner

The runner VM (`infra/modules/runner/`) lives in its own dedicated `runner-subnet` (not
`apps-subnet`, which is delegated to `Microsoft.App/environments` for Container Apps and can't
host any other resource type), has no public IP, and reaches Key Vault/Cosmos DB via their
private endpoints in `data-subnet`. `data-subnet-nsg`'s inbound rule explicitly allows both
`apps-subnet` and `runner-subnet` on port 443 - without the runner-subnet entry, its traffic gets
silently dropped by the implicit deny-all, which looks like a hung connection
("context deadline exceeded"), not a clean permission error. It's outbound-only (to github.com
and Azure management endpoints) - no inbound rules are needed there, and `runner-subnet-nsg`
already allows outbound HTTPS to the internet.

After `terraform apply` creates the VM, it still needs to be registered with GitHub once -
see the detailed step-by-step in `infra/modules/runner/outputs.tf`. In short: reach the VM via
Bastion or a jump host in the VNet, get a registration token from the repo's
Settings → Actions → Runners page, then run `./config.sh` and install it as a service.
