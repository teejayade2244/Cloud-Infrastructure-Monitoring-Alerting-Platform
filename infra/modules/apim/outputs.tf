output "id" {
  value = azurerm_api_management.main.id
}

output "gateway_url" {
  value = azurerm_api_management.main.gateway_url
}

output "principal_id" {
  value = azurerm_api_management.main.identity[0].principal_id
}
