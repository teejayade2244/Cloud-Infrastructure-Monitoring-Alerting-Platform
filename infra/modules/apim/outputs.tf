output "id" {
  value = azurerm_api_management.main.id
}

output "gateway_url" {
  value = azurerm_api_management.main.gateway_url
}

output "principal_id" {
  value = azurerm_api_management.main.identity[0].principal_id
}

output "apim_gateway_url" {
  value = azurerm_api_management.main.gateway_url
}

output "apim_name" {
  value = azurerm_api_management.main.name
}

output "apim_principal_id" {
  value = azurerm_api_management.main.identity[0].principal_id
}
