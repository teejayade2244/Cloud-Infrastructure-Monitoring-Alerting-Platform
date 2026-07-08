output "static_web_app_url" {
  value = "https://${azurerm_static_web_app.main.default_host_name}"
}

output "static_web_app_api_key" {
  description = "Deployment token for GitHub Actions CI/CD"
  value       = azurerm_static_web_app.main.api_key
  sensitive   = true
}
