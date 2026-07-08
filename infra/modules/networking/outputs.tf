output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "apps_subnet_id" {
  value = azurerm_subnet.apps.id
}

output "data_subnet_id" {
  value = azurerm_subnet.data.id
}

output "gateway_subnet_id" {
  value = azurerm_subnet.gateway.id
}

output "cosmos_private_dns_zone_id" {
  value = azurerm_private_dns_zone.cosmos.id
}

output "cosmos_private_dns_zone_name" {
  value = azurerm_private_dns_zone.cosmos.name
}

output "keyvault_private_dns_zone_id" {
  value = azurerm_private_dns_zone.keyvault.id
}

output "keyvault_private_dns_zone_name" {
  value = azurerm_private_dns_zone.keyvault.name
}
