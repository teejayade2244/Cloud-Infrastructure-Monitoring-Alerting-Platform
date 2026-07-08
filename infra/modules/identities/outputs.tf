output "events_identity_id" {
  value = azurerm_user_assigned_identity.events.id
}

output "events_identity_principal_id" {
  value = azurerm_user_assigned_identity.events.principal_id
}

output "events_identity_client_id" {
  value = azurerm_user_assigned_identity.events.client_id
}

output "incidents_identity_id" {
  value = azurerm_user_assigned_identity.incidents.id
}

output "incidents_identity_principal_id" {
  value = azurerm_user_assigned_identity.incidents.principal_id
}

output "incidents_identity_client_id" {
  value = azurerm_user_assigned_identity.incidents.client_id
}

output "functions_identity_id" {
  value = azurerm_user_assigned_identity.functions.id
}

output "functions_identity_principal_id" {
  value = azurerm_user_assigned_identity.functions.principal_id
}

output "functions_identity_client_id" {
  value = azurerm_user_assigned_identity.functions.client_id
}
