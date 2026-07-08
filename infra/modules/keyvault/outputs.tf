output "key_vault_id" {
  value = azurerm_key_vault.main.id
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "cosmos_endpoint_secret_id" {
  value = azurerm_key_vault_secret.cosmos_endpoint.id
}

output "servicebus_namespace_secret_id" {
  value = azurerm_key_vault_secret.servicebus_namespace.id
}

output "appinsights_connection_string_secret_id" {
  value = azurerm_key_vault_secret.appinsights_connection_string.id
}
