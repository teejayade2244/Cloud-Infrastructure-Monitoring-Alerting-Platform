output "logic_app_id" {
  value = azurerm_logic_app_workflow.main.id
}

output "logic_app_name" {
  value = azurerm_logic_app_workflow.main.name
}

output "logic_app_principal_id" {
  value = azurerm_logic_app_workflow.main.identity[0].principal_id
}

# No trigger is defined yet (triggers/actions are configured manually in the portal), so there's
# no trigger-specific callback URL to reference. This is the workflow's base access endpoint;
# once an HTTP trigger is added in the portal, its own callback URL will differ from this.
output "logic_app_callback_url" {
  value = azurerm_logic_app_workflow.main.access_endpoint
}
