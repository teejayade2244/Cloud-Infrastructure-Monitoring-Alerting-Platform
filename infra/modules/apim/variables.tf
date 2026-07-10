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

variable "publisher_name" {
  type    = string
  default = "InfraMonitor"
}

variable "publisher_email" {
  type = string
}

variable "sku_name" {
  type    = string
  default = "Developer_1"
}

variable "events_service_url" {
  description = "Base URL (with scheme) of the events-service Container App"
  type        = string
}

variable "incidents_service_url" {
  description = "Base URL (with scheme) of the incidents-service Container App"
  type        = string
}

variable "frontend_url" {
  description = "Static Web App URL allowed as a CORS origin on the published APIs"
  type        = string
}
