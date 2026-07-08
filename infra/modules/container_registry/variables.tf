variable "name" {
  description = "ACR name (no hyphens, globally unique)"
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

variable "sku" {
  type    = string
  default = "Basic"
}

variable "identity_principal_ids" {
  description = "Map of identity name => principal_id to grant AcrPull"
  type        = map(string)
}
