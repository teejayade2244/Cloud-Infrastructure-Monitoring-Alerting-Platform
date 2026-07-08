resource "azurerm_user_assigned_identity" "events" {
  name                = "${var.name_prefix}-events-identity-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "incidents" {
  name                = "${var.name_prefix}-incidents-identity-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "functions" {
  name                = "${var.name_prefix}-functions-identity-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}
