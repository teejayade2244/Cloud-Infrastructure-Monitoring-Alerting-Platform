variable "resource_group_name" {
  type = string
}

variable "resource_group_id" {
  description = "Resource ID of the resource group, used as the Contributor role assignment scope"
  type        = string
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

variable "tags" {
  type = map(string)
}

variable "runner_subnet_id" {
  description = "Dedicated subnet for the runner VM - cannot be apps-subnet, which is delegated to Microsoft.App/environments and can't host any other resource type"
  type        = string
}

variable "runner_ssh_public_key" {
  description = "SSH public key for the GitHub Actions runner VM"
  type        = string
  sensitive   = true
}
