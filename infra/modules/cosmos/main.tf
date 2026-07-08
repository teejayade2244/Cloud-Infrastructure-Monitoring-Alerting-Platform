resource "azurerm_cosmosdb_account" "main" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  identity {
    type = "SystemAssigned"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = false
  }

  # NOTE: public_network_access_enabled = false blocks ALL public data-plane traffic outright,
  # including anything in ip_range_filter - the IP allowlist only has any effect while public
  # network access is enabled. Locking down access relies on ip_range_filter, not this flag.
  public_network_access_enabled = true
  ip_range_filter               = var.allowed_ip_ranges

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = var.database_name
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "events" {
  name                = "Events"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/environment"]
  throughput          = var.container_throughput
}

resource "azurerm_cosmosdb_sql_container" "incidents" {
  name                = "Incidents"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/severity"]
  throughput          = var.container_throughput
}

resource "azurerm_cosmosdb_sql_container" "notifications" {
  name                = "Notifications"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/type"]
  throughput          = var.container_throughput
}

# Cosmos DB has its own data-plane RBAC system, separate from Azure RBAC.
# "Cosmos DB Built-in Data Contributor" is the built-in role GUID 00000000-0000-0000-0000-000000000002.
resource "azurerm_cosmosdb_sql_role_assignment" "data_contributor" {
  for_each = var.identity_principal_ids

  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = each.value
  scope               = azurerm_cosmosdb_account.main.id
}

resource "azurerm_private_endpoint" "cosmos" {
  name                = "cosmos-private-endpoint-dev"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.data_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "cosmos-privateserviceconnection"
    private_connection_resource_id = azurerm_cosmosdb_account.main.id
    subresource_names              = ["Sql"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}
