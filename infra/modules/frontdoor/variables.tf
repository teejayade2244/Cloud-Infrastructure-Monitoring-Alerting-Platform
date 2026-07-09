variable "resource_group_name" {
  type = string
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "static_web_app_hostname" {
  description = "Frontend origin - the Static Web App's hostname (no scheme)"
  type        = string
}

variable "apim_gateway_hostname" {
  description = "API origin - the APIM gateway's hostname (no scheme)"
  type        = string
}
