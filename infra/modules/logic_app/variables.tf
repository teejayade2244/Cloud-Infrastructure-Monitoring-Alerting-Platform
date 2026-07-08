variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "service_bus_namespace_id" {
  description = "Service Bus namespace resource ID - the Logic App's system identity is granted Data Receiver on this scope"
  type        = string
}

variable "cosmos_account_name" {
  type = string
}

variable "cosmos_account_id" {
  description = "Cosmos DB account resource ID, used to build the built-in Data Contributor role definition ID"
  type        = string
}

variable "tags" {
  type = map(string)
}
