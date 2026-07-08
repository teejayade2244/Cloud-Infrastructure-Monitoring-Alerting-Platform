resource "azurerm_logic_app_workflow" "main" {
  name                = "${var.project}-notifications-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "servicebus_receiver" {
  scope                = var.service_bus_namespace_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_logic_app_workflow.main.identity[0].principal_id
}

# azurerm_role_assignment retries internally when a freshly-created system-assigned identity
# hasn't propagated through AAD yet - azurerm_cosmosdb_sql_role_assignment does not, and fails
# outright with "principal ID ... was not found" if it runs too soon after the identity is
# created. Give AAD a moment to catch up before attempting the Cosmos role assignment.
resource "time_sleep" "wait_for_identity_propagation" {
  depends_on      = [azurerm_logic_app_workflow.main]
  create_duration = "30s"
}

# Cosmos DB has its own data-plane RBAC system, separate from Azure RBAC.
# "Cosmos DB Built-in Data Contributor" is the built-in role GUID 00000000-0000-0000-0000-000000000002.
resource "azurerm_cosmosdb_sql_role_assignment" "data_contributor" {
  resource_group_name = var.resource_group_name
  account_name        = var.cosmos_account_name
  role_definition_id  = "${var.cosmos_account_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_logic_app_workflow.main.identity[0].principal_id
  scope               = var.cosmos_account_id

  depends_on = [time_sleep.wait_for_identity_propagation]
}
