resource "azurerm_storage_account" "functions" {
  name                     = var.storage_account_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

resource "azurerm_service_plan" "functions" {
  name                = var.service_plan_name != "" ? var.service_plan_name : "${var.name_prefix}-functions-plan-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  # Y1 (Consumption/Dynamic) is blocked on this subscription (ServerFarmCreationNotAllowed /
  # SubscriptionIsOverQuotaForSku) across every region and auth method tested. B1 is a paid
  # dedicated tier not subject to that same anti-abuse restriction.
  sku_name = "B1"
  tags     = var.tags
}

resource "azurerm_linux_function_app" "main" {
  name                = var.function_app_name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.functions.id
  tags                = var.tags

  storage_account_name          = azurerm_storage_account.functions.name
  storage_uses_managed_identity = true

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [var.functions_identity_id]
  }

  site_config {
    application_stack {
      node_version = "22"
    }
  }

  app_settings = {
    FUNCTIONS_WORKER_RUNTIME                         = "node"
    COSMOS_ENDPOINT                                  = var.cosmos_endpoint
    "SERVICEBUS_CONNECTION__fullyQualifiedNamespace" = var.servicebus_namespace_fqdn
    APPLICATIONINSIGHTS_CONNECTION_STRING            = var.appinsights_connection_string
  }
}

resource "azurerm_role_assignment" "storage_blob_data_owner" {
  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "storage_queue_data_contributor" {
  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}

# Cosmos DB data-plane RBAC (built-in "Cosmos DB Built-in Data Contributor" role, GUID 00000000-0000-0000-0000-000000000002).
resource "azurerm_cosmosdb_sql_role_assignment" "functions_data_contributor" {
  resource_group_name = var.resource_group_name
  account_name        = var.cosmos_account_name
  role_definition_id  = "${var.cosmos_account_id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_linux_function_app.main.identity[0].principal_id
  scope               = var.cosmos_account_id
}

resource "azurerm_role_assignment" "servicebus_receiver" {
  scope                = var.servicebus_namespace_id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.main.identity[0].principal_id
}
