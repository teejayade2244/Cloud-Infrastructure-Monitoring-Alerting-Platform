variable "name_prefix" {
  description = "Project name prefix used to build resource names"
  type        = string
}

variable "environment" {
  description = "Environment suffix (e.g. dev)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy networking resources into"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
}

variable "vnet_address_space" {
  description = "Address space for the VNet"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "apps_subnet_prefix" {
  type    = list(string)
  default = ["10.1.1.0/24"]
}

variable "data_subnet_prefix" {
  type    = list(string)
  default = ["10.1.2.0/24"]
}

variable "gateway_subnet_prefix" {
  type    = list(string)
  default = ["10.1.3.0/24"]
}
