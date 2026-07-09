# Terraform CI/CD Pipeline

`terraform.yml` plans and applies the Terraform project at `infra/` whenever it changes. It
authenticates to Azure via **OIDC / workload identity federation** (no client secret in GitHub),
and runs on a **self-hosted runner VM inside the VNet** (`infra/modules/runner/`) so it can reach
Key Vault and Cosmos DB through their private endpoints without any public firewall exception.

## One-time setup: Federated Credential on the service principal

OIDC needs the Azure AD app registration to trust GitHub's OIDC tokens for this specific repo.
This is now managed by Terraform (`infra/modules/oidc/`) rather than manual `az cli` commands -
`terraform apply` creates two federated credentials on the app registration: one for pushes to
`main` (covers `push` and a manual `workflow_dispatch` run against `main`), one for pull requests
(covers the `terraform-plan` job running on a PR).

**Bootstrap chicken-and-egg**: the *first* apply that creates these credentials can't run from
CI, since CI's own OIDC login depends on the credentials already existing. Run that first apply
locally (`terraform apply`, authenticated via your own `az login` session) before ever relying on
the GitHub Actions pipeline. After that, both the pipeline and further local runs authenticate
via the federated credentials Terraform itself now manages.

If you ever rename the repo, move it to another org, or change which branch triggers apply,
update `github_org`/`github_repo` in `terraform.tfvars` (or the `subject` values directly in
`modules/oidc/main.tf` if the trigger ref changes) and re-apply - a mismatched subject fails
`azure/login@v2` with an AADSTS70021 error, not something obviously about federated credentials.

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
| `TF_VAR_CREATE_APIM` | `false` |
| `TF_VAR_KEYVAULT_ALLOWED_IP_RANGES` | `[]` |
| `TF_VAR_COSMOS_ALLOWED_IP_RANGES` | `[]` |

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

The runner VM (`infra/modules/runner/`) lives in `apps-subnet`, has no public IP, and reaches
Key Vault/Cosmos DB via their private endpoints. It's outbound-only (to github.com and Azure
management endpoints) - no inbound rules are needed, and the apps-subnet NSG already allows
outbound HTTPS to the internet via the default rule.

After `terraform apply` creates the VM, it still needs to be registered with GitHub once -
see the detailed step-by-step in `infra/modules/runner/outputs.tf`. In short: reach the VM via
Bastion or a jump host in the VNet, get a registration token from the repo's
Settings → Actions → Runners page, then run `./config.sh` and install it as a service.
