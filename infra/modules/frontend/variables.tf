variable "name" {
  type = string
}

variable "location" {
  description = "Static Web Apps is not available in uksouth - use a supported region (e.g. eastus2)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "sku_tier" {
  type    = string
  default = "Free"
}

variable "sku_size" {
  type    = string
  default = "Free"
}
