variable "name" {
  description = "Key Vault name (max 24 chars)"
  type        = string
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

variable "tenant_id" {
  type = string
}

variable "officer_principal_ids" {
  description = "Principal IDs granted Key Vault Secrets Officer (human operator + the Terraform service principal)"
  type        = list(string)
}

variable "secrets_user_principal_ids" {
  description = "Map of identity name => principal_id granted Key Vault Secrets User"
  type        = map(string)
}

variable "data_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "allowed_ip_ranges" {
  description = "Public IP CIDRs allowed through the Key Vault firewall (e.g. operator/CI egress IP) once public network access is restricted"
  type        = list(string)
  default     = []
}

variable "cosmos_endpoint" {
  description = "Cosmos DB endpoint, stored as the cosmos-endpoint secret"
  type        = string
}

variable "servicebus_namespace_fqdn" {
  description = "Service Bus namespace FQDN, stored as the servicebus-namespace secret"
  type        = string
}

variable "appinsights_connection_string" {
  description = "Application Insights connection string, stored as the appinsights-connection-string secret"
  type        = string
  sensitive   = true
}
