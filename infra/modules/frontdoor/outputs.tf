output "frontdoor_endpoint_url" {
  value = "https://${azurerm_cdn_frontdoor_endpoint.main.host_name}"
}

output "frontdoor_endpoint_hostname" {
  value = azurerm_cdn_frontdoor_endpoint.main.host_name
}

output "frontdoor_profile_id" {
  value = azurerm_cdn_frontdoor_profile.main.id
}
