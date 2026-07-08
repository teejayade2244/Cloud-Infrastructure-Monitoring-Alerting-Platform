variable "name" {
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

variable "database_name" {
  type    = string
  default = "InfraMonitorDB"
}

variable "container_throughput" {
  type    = number
  default = 400
}

variable "identity_principal_ids" {
  description = "Map of identity name => principal_id granted Cosmos DB Built-in Data Contributor"
  type        = map(string)
}

variable "data_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "allowed_ip_ranges" {
  description = "Public IP CIDRs allowed through the Cosmos DB firewall while public network access is disabled"
  type        = list(string)
  default     = []
}
