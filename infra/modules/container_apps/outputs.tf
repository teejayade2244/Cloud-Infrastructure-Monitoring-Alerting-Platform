output "environment_id" {
  value = azurerm_container_app_environment.main.id
}

output "events_app_id" {
  value = azurerm_container_app.events.id
}

output "events_app_fqdn" {
  value = azurerm_container_app.events.latest_revision_fqdn
}

output "incidents_app_id" {
  value = azurerm_container_app.incidents.id
}

output "incidents_app_fqdn" {
  value = azurerm_container_app.incidents.latest_revision_fqdn
}
