output "github_actions_main_credential_id" {
  value = azuread_application_federated_identity_credential.github_actions_main.credential_id
}

output "github_actions_pr_credential_id" {
  value = azuread_application_federated_identity_credential.github_actions_pr.credential_id
}
