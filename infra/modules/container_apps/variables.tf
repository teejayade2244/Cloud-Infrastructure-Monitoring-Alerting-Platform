variable "environment_name" {
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

variable "log_analytics_workspace_id" {
  type = string
}

variable "apps_subnet_id" {
  type = string
}

variable "acr_login_server" {
  type = string
}

variable "cosmos_endpoint_secret_id" {
  type = string
}

variable "servicebus_namespace_secret_id" {
  type = string
}

variable "appinsights_connection_string_secret_id" {
  type = string
}

variable "events_identity_id" {
  type = string
}

variable "events_identity_client_id" {
  type = string
}

variable "events_service_image" {
  type    = string
  default = "events-service:v1"
}

variable "incidents_identity_id" {
  type = string
}

variable "incidents_identity_client_id" {
  type = string
}

variable "incidents_service_image" {
  type    = string
  default = "incidents-service:v1"
}

variable "functions_identity_id" {
  description = "User-assigned identity used by the CreateIncident Container Apps Job"
  type        = string
}

variable "functions_identity_client_id" {
  type = string
}

variable "servicebus_namespace" {
  description = "Service Bus namespace hostname, e.g. inframonitorsb-dev.servicebus.windows.net"
  type        = string
}

variable "cosmos_endpoint" {
  description = "Key Vault secret ID for the cosmos-endpoint secret"
  type        = string
}

variable "appinsights_connection_string" {
  type      = string
  sensitive = true
}

variable "incident_functions_image" {
  type    = string
  default = "incident-functions:v1"
}
