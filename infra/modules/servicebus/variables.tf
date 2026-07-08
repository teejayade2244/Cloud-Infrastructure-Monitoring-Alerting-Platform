variable "name" {
  description = "Service Bus namespace name"
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
  default = "Standard"
}

variable "topic_name" {
  type    = string
  default = "infrastructure-events"
}

variable "topic_max_size_mb" {
  type    = number
  default = 1024
}

variable "topic_default_ttl" {
  type    = string
  default = "P1D"
}

variable "subscription_max_delivery_count" {
  type    = number
  default = 3
}

variable "sender_principal_id" {
  description = "Principal ID granted Azure Service Bus Data Sender (events identity)"
  type        = string
}

variable "receiver_principal_id" {
  description = "Principal ID granted Azure Service Bus Data Receiver (functions identity)"
  type        = string
}
