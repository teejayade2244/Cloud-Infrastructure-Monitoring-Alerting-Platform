variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}

variable "client_id" {
  description = "Service principal (app registration) client ID used by Terraform. Leave unset (null) to fall back to Azure CLI (az login) authentication instead."
  type        = string
  default     = null
}

variable "client_secret" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Not used when OIDC is enabled. Kept for local development."
}

variable "environment" {
  description = "Environment suffix"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "uksouth"
}

variable "project" {
  description = "Project name prefix"
  type        = string
  default     = "inframonitor"
}

variable "publisher_email" {
  description = "Publisher email for APIM"
  type        = string
}

variable "current_user_object_id" {
  description = "Object ID of the human operator to grant Key Vault Secrets Officer access"
  type        = string
}

variable "create_apim" {
  description = "APIM Developer tier is expensive to leave running - set false to skip provisioning it"
  type        = bool
  default     = true
}

variable "keyvault_allowed_ip_ranges" {
  description = "Public IP CIDRs (e.g. your egress IP) allowed through the Key Vault firewall while public network access is disabled. Needed so `terraform apply` can manage secrets from outside the VNet."
  type        = list(string)
  default     = []
}

variable "cosmos_allowed_ip_ranges" {
  description = "Public IP CIDRs allowed through the Cosmos DB firewall while public network access is disabled"
  type        = list(string)
  default     = []
}

variable "events_service_image_tag" {
  type    = string
  default = "v1"
}

variable "incidents_service_image_tag" {
  type    = string
  default = "v1"
}

variable "frontend_location" {
  description = "Azure Static Web Apps is not available in uksouth - deploy it to a supported region"
  type        = string
  default     = "eastus2"
}

variable "functions_location" {
  description = "Region for the Functions module (storage account, service plan, function app). Override to diagnose the uksouth serverfarm 'Forbidden' error against a different region."
  type        = string
  default     = "uksouth"
}

variable "functions_service_plan_name" {
  description = "Override the service plan name - needed when testing functions_location against a region other than uksouth, since the default name is already bound to uksouth. Empty string uses the default naming convention."
  type        = string
  default     = ""
}

variable "runner_ssh_public_key" {
  description = "SSH public key for the GitHub Actions runner VM"
  type        = string
  sensitive   = true
}

variable "github_org" {
  description = "GitHub username/organisation that owns the repo (used for OIDC federated credential subjects)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (used for OIDC federated credential subjects)"
  type        = string
}
