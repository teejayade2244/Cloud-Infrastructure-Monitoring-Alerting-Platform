
terraform {
  backend "azurerm" {
    resource_group_name  = "infra-terraform-rg"
    storage_account_name = "inframonitortfstate"
    container_name       = "tfstate"
    key                  = "inframonitor-dev.tfstate"
  }
}
