variable "name_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "storage_account_name" {
  description = "Storage account name (no hyphens, globally unique)"
  type        = string
}

variable "function_app_name" {
  type = string
}

variable "service_plan_name" {
  description = "Override the service plan name (e.g. for a region diagnostic test that would otherwise collide with the default name already bound elsewhere). Empty string falls back to the default naming convention."
  type        = string
  default     = ""
}

variable "functions_identity_id" {
  description = "User-assigned identity used for Key Vault / ACR access alongside the app's system-assigned identity"
  type        = string
}

variable "cosmos_endpoint" {
  type = string
}

variable "servicebus_namespace_fqdn" {
  type = string
}

variable "appinsights_connection_string" {
  type      = string
  sensitive = true
}

variable "cosmos_account_id" {
  description = "Cosmos DB account resource ID, used to build the built-in Data Contributor role definition ID"
  type        = string
}

variable "cosmos_account_name" {
  type = string
}

variable "servicebus_namespace_id" {
  type = string
}
