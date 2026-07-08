resource "azurerm_key_vault" "main" {
  name                       = var.name
  location                   = var.location
  resource_group_name        = var.resource_group_name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7

  # Dev environment: allow the vault to be purged on destroy so the sandbox can be torn down cleanly.
  purge_protection_enabled = false

  rbac_authorization_enabled = true

  # NOTE: public_network_access_enabled = false blocks ALL public traffic outright, including
  # anything in network_acls.ip_rules - the IP allowlist below only has any effect while public
  # network access is enabled. Locking down access is achieved via the "Deny" default_action here,
  # not by disabling public network access.
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_ranges
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "secrets_officer" {
  for_each = toset(var.officer_principal_ids)

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "secrets_user" {
  for_each = var.secrets_user_principal_ids

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

resource "azurerm_private_endpoint" "keyvault" {
  name                = "keyvault-private-endpoint-dev"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.data_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "keyvault-privateserviceconnection"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

# Secrets are written via the RBAC-authorized data plane, so they must wait until the
# Terraform principal's Secrets Officer role assignment and the private endpoint both exist
# (the vault has public network access disabled).
resource "azurerm_key_vault_secret" "cosmos_endpoint" {
  name         = "cosmos-endpoint"
  value        = var.cosmos_endpoint
  key_vault_id = azurerm_key_vault.main.id
  tags         = var.tags

  depends_on = [
    azurerm_role_assignment.secrets_officer,
    azurerm_private_endpoint.keyvault,
  ]
}

resource "azurerm_key_vault_secret" "servicebus_namespace" {
  name         = "servicebus-namespace"
  value        = var.servicebus_namespace_fqdn
  key_vault_id = azurerm_key_vault.main.id
  tags         = var.tags

  depends_on = [
    azurerm_role_assignment.secrets_officer,
    azurerm_private_endpoint.keyvault,
  ]
}

resource "azurerm_key_vault_secret" "appinsights_connection_string" {
  name         = "appinsights-connection-string"
  value        = var.appinsights_connection_string
  key_vault_id = azurerm_key_vault.main.id
  tags         = var.tags

  depends_on = [
    azurerm_role_assignment.secrets_officer,
    azurerm_private_endpoint.keyvault,
  ]
}
