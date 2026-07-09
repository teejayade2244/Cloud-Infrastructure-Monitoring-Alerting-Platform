output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

# --- Networking ---

output "vnet_id" {
  value = module.networking.vnet_id
}

output "apps_subnet_id" {
  value = module.networking.apps_subnet_id
}

output "data_subnet_id" {
  value = module.networking.data_subnet_id
}

# --- Observability ---

output "log_analytics_workspace_id" {
  value = module.observability.log_analytics_workspace_id
}

output "app_insights_connection_string" {
  value     = module.observability.app_insights_connection_string
  sensitive = true
}

# --- Identities ---

output "events_identity_client_id" {
  value = module.identities.events_identity_client_id
}

output "incidents_identity_client_id" {
  value = module.identities.incidents_identity_client_id
}

output "functions_identity_client_id" {
  value = module.identities.functions_identity_client_id
}

# --- Container Registry ---

output "acr_login_server" {
  value = module.container_registry.login_server
}

# --- Key Vault ---

output "key_vault_uri" {
  value = module.keyvault.key_vault_uri
}

# --- Cosmos DB ---

output "cosmos_endpoint" {
  value = module.cosmos.endpoint
}

output "cosmos_database_name" {
  value = module.cosmos.database_name
}

# --- Service Bus ---

output "servicebus_namespace_fqdn" {
  value = module.servicebus.namespace_fqdn
}

output "servicebus_topic_name" {
  value = module.servicebus.topic_name
}

# --- Container Apps ---

output "events_service_fqdn" {
  value = module.container_apps.events_app_fqdn
}

output "incidents_service_fqdn" {
  value = module.container_apps.incidents_app_fqdn
}

# --- Functions ---
# Disabled along with module.functions in main.tf - see the comment there.

# output "function_app_default_hostname" {
#   value = module.functions.default_hostname
# }
#
# output "function_app_name" {
#   value = module.functions.function_app_name
# }

# --- Frontend ---

output "static_web_app_url" {
  value = module.frontend.static_web_app_url
}

output "static_web_app_api_key" {
  value     = module.frontend.static_web_app_api_key
  sensitive = true
}

# --- APIM (only present when create_apim = true) ---

output "apim_gateway_url" {
  value = var.create_apim ? module.apim[0].gateway_url : null
}

# --- Front Door (only present when create_frontdoor = true and create_apim = true) ---

output "frontdoor_endpoint_url" {
  value = var.create_frontdoor && var.create_apim ? module.frontdoor[0].frontdoor_endpoint_url : null
}

# --- GitHub Actions runner ---

output "runner_private_ip" {
  value = module.runner.runner_private_ip
}

output "runner_vm_name" {
  value = module.runner.runner_vm_name
}
