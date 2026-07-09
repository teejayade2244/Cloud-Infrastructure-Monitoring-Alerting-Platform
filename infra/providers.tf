terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  use_oidc        = true


  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ApiManagement",
    "Microsoft.DocumentDB",
    "Microsoft.ServiceBus",
    "Microsoft.ContainerRegistry",
    "Microsoft.KeyVault",
    "Microsoft.Web",
    "Microsoft.Insights",
    "Microsoft.OperationalInsights",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Storage",
    "Microsoft.Compute",
    "Microsoft.Quota",
  ]

  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Authenticates as the same app registration/service principal as the azurerm provider above,
# via the same OIDC federated credential - needed for the azuread_application data source and
# federated identity credential resources in modules/oidc.
provider "azuread" {
  tenant_id = var.tenant_id
  client_id = var.client_id
  use_oidc  = true
}
