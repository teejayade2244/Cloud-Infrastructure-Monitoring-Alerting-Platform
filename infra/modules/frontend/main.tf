resource "azurerm_static_web_app" "main" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_tier            = var.sku_tier
  sku_size            = var.sku_size
  tags                = var.tags

  # The GitHub CI/CD link (repository_url/branch/token) and app_settings are managed by the
  # Static Web Apps deployment workflow, not Terraform - without this, every apply would try to
  # null them out and disconnect the live integration.
  lifecycle {
    ignore_changes = [
      repository_url,
      repository_branch,
      repository_token,
      app_settings,
    ]
  }
}
