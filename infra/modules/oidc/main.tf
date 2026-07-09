data "azuread_application" "terraform_sp" {
  client_id = var.terraform_client_id
}

# NOTE: azuread_application_federated_identity_credential (azuread provider), not
# azurerm_federated_identity_credential (azurerm provider) - the latter federates a
# User Assigned Managed Identity (azurerm_user_assigned_identity), not an Azure AD app
# registration / service principal, which is what Terraform authenticates as here.
resource "azuread_application_federated_identity_credential" "github_actions_main" {
  application_id = data.azuread_application.terraform_sp.id
  display_name   = "inframonitor-github-actions-main"
  description    = "GitHub Actions OIDC - push / workflow_dispatch on main"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
}

resource "azuread_application_federated_identity_credential" "github_actions_pr" {
  application_id = data.azuread_application.terraform_sp.id
  display_name   = "inframonitor-github-actions-pr"
  description    = "GitHub Actions OIDC - pull_request"
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_org}/${var.github_repo}:pull_request"
}
