# Looked up explicitly by client_id rather than via data.azurerm_client_config.current, which
# resolves to whichever identity happens to be running Terraform right now (the human operator
# locally, or the SP in CI) - using that dynamically caused Terraform to destroy the SP's own
# Key Vault Secrets Officer grant every time a human ran apply locally, then recreate it the next
# time CI ran, flip-flopping depending on who applied last. This is a fixed, known identity
# regardless of who's currently authenticated.
data "azuread_service_principal" "terraform_sp" {
  client_id = var.client_id
}

locals {
  common_tags = {
    environment = var.environment
    project     = var.project
    managed_by  = "terraform"
  }

  # De-duplicated: the human operator and the Terraform service principal may be the same
  # principal in some setups, so this is passed through toset() downstream.
  keyvault_officer_principal_ids = [
    var.current_user_object_id,
    data.azuread_service_principal.terraform_sp.object_id,
  ]
}

resource "azurerm_resource_group" "main" {
  name     = "${var.project}-rg-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

module "networking" {
  source = "./modules/networking"

  name_prefix         = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

module "observability" {
  source = "./modules/observability"

  name_prefix         = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

module "identities" {
  source = "./modules/identities"

  name_prefix         = var.project
  environment         = var.environment
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

module "container_registry" {
  source = "./modules/container_registry"

  name                = "${var.project}acr${var.environment}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  identity_principal_ids = {
    events    = module.identities.events_identity_principal_id
    incidents = module.identities.incidents_identity_principal_id
    functions = module.identities.functions_identity_principal_id
  }
}

module "servicebus" {
  source = "./modules/servicebus"

  name                = "${var.project}sb-${var.environment}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  sender_principal_id   = module.identities.events_identity_principal_id
  receiver_principal_id = module.identities.functions_identity_principal_id
}

module "cosmos" {
  source = "./modules/cosmos"

  name                = "${var.project}-cosmos-${var.environment}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  data_subnet_id      = module.networking.data_subnet_id
  private_dns_zone_id = module.networking.cosmos_private_dns_zone_id
  allowed_ip_ranges   = var.cosmos_allowed_ip_ranges

  identity_principal_ids = {
    events    = module.identities.events_identity_principal_id
    incidents = module.identities.incidents_identity_principal_id
    functions = module.identities.functions_identity_principal_id
  }
}

module "keyvault" {
  source = "./modules/keyvault"

  name                = "${var.project}-kv-${var.environment}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
  tenant_id           = var.tenant_id

  officer_principal_ids = local.keyvault_officer_principal_ids
  secrets_user_principal_ids = {
    events    = module.identities.events_identity_principal_id
    incidents = module.identities.incidents_identity_principal_id
    functions = module.identities.functions_identity_principal_id
  }

  data_subnet_id      = module.networking.data_subnet_id
  private_dns_zone_id = module.networking.keyvault_private_dns_zone_id
  allowed_ip_ranges   = var.keyvault_allowed_ip_ranges

  # Real values from the resources they describe, not placeholders - Terraform's
  # dependency graph takes care of creating cosmos/observability first.
  cosmos_endpoint               = module.cosmos.endpoint
  servicebus_namespace_fqdn     = module.servicebus.namespace_fqdn
  appinsights_connection_string = module.observability.app_insights_connection_string
}

module "container_apps" {
  source = "./modules/container_apps"

  environment_name    = "infra-monitor-env-dev"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  apps_subnet_id             = module.networking.apps_subnet_id
  acr_login_server           = module.container_registry.login_server

  cosmos_endpoint_secret_id               = module.keyvault.cosmos_endpoint_secret_id
  servicebus_namespace_secret_id          = module.keyvault.servicebus_namespace_secret_id
  appinsights_connection_string_secret_id = module.keyvault.appinsights_connection_string_secret_id

  events_identity_id        = module.identities.events_identity_id
  events_identity_client_id = module.identities.events_identity_client_id
  events_service_image      = "events-service:${var.events_service_image_tag}"

  incidents_identity_id        = module.identities.incidents_identity_id
  incidents_identity_client_id = module.identities.incidents_identity_client_id
  incidents_service_image      = "incidents-service:${var.incidents_service_image_tag}"

  functions_identity_id         = module.identities.functions_identity_id
  functions_identity_client_id  = module.identities.functions_identity_client_id
  servicebus_namespace          = module.servicebus.namespace_hostname
  cosmos_endpoint               = module.keyvault.cosmos_endpoint_secret_id
  appinsights_connection_string = module.observability.app_insights_connection_string
}

# TEMPORARILY DISABLED: azurerm_service_plan creation in this subscription is blocked
# (ExtendedCode 70007 / "Current Limit (Total VMs): 0"), reproduced across uksouth/canadacentral,
# Y1 and B1 SKUs, and both service-principal and interactive auth - needs an Azure Support
# quota ticket to lift. Re-enable this module once that's resolved.
# module "functions" {
#   source = "./modules/functions"
#
#   name_prefix         = var.project
#   environment         = var.environment
#   location            = var.functions_location
#   resource_group_name = azurerm_resource_group.main.name
#   tags                = local.common_tags
#
#   storage_account_name = "${var.project}func${var.environment}"
#   function_app_name    = "${var.project}-functions-${var.environment}"
#   service_plan_name    = var.functions_service_plan_name
#
#   functions_identity_id = module.identities.functions_identity_id
#
#   cosmos_endpoint               = module.cosmos.endpoint
#   cosmos_account_id             = module.cosmos.cosmos_account_id
#   cosmos_account_name           = module.cosmos.cosmos_account_name
#   servicebus_namespace_fqdn     = module.servicebus.namespace_fqdn
#   servicebus_namespace_id       = module.servicebus.namespace_id
#   appinsights_connection_string = module.observability.app_insights_connection_string
# }

module "apim" {
  count  = var.create_apim ? 1 : 0
  source = "./modules/apim"

  name                = "${var.project}-apim-${var.environment}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  publisher_name  = "InfraMonitor"
  publisher_email = var.publisher_email
}

module "logic_app" {
  source = "./modules/logic_app"

  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  project             = var.project
  environment         = var.environment
  tags                = local.common_tags

  service_bus_namespace_id = module.servicebus.namespace_id
  cosmos_account_name      = module.cosmos.account_name
  cosmos_account_id        = module.cosmos.account_id
}

module "frontend" {
  source = "./modules/frontend"

  name                = "${var.project}-frontend-${var.environment}"
  location            = var.frontend_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

module "runner" {
  source = "./modules/runner"

  resource_group_name = azurerm_resource_group.main.name
  resource_group_id   = azurerm_resource_group.main.id
  location            = var.location
  project             = var.project
  environment         = var.environment
  tags                = local.common_tags

  runner_subnet_id      = module.networking.runner_subnet_id
  runner_ssh_public_key = var.runner_ssh_public_key
}

module "oidc" {
  source = "./modules/oidc"

  github_org          = var.github_org
  github_repo         = var.github_repo
  terraform_client_id = var.client_id
}
