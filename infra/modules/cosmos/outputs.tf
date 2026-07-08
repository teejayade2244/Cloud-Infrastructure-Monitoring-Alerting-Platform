output "cosmos_account_id" {
  value = azurerm_cosmosdb_account.main.id
}

output "cosmos_account_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "database_name" {
  value = azurerm_cosmosdb_sql_database.main.name
}

# Aliases of cosmos_account_name / cosmos_account_id for consumers that expect the shorter names.
output "account_name" {
  value = azurerm_cosmosdb_account.main.name
}

output "account_id" {
  value = azurerm_cosmosdb_account.main.id
}
