output "environment_id" {
  value = azurerm_container_app_environment.main.id
}

output "events_app_id" {
  value = azurerm_container_app.events.id
}

# ingress[0].fqdn is the stable, app-level FQDN - latest_revision_fqdn (despite the name being
# easy to assume is "current"/stable) is specific to whichever revision is newest and changes on
# every deployment, which broke the APIM backend URLs pointing at a now-stale revision.
output "events_app_fqdn" {
  value = azurerm_container_app.events.ingress[0].fqdn
}

output "incidents_app_id" {
  value = azurerm_container_app.incidents.id
}

output "incidents_app_fqdn" {
  value = azurerm_container_app.incidents.ingress[0].fqdn
}

# Aliases of events_app_fqdn / incidents_app_fqdn above - the apim module consumes these
# specific names when building each backend's service URL.
output "events_service_fqdn" {
  value = azurerm_container_app.events.ingress[0].fqdn
}

output "incidents_service_fqdn" {
  value = azurerm_container_app.incidents.ingress[0].fqdn
}
