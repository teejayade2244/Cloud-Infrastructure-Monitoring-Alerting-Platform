variable "github_org" {
  description = "GitHub username/organisation that owns the repo"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}

variable "terraform_client_id" {
  description = "Client ID of the Azure AD app registration / service principal Terraform runs as"
  type        = string
}
