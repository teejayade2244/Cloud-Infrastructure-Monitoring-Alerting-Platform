output "namespace_id" {
  value = azurerm_servicebus_namespace.main.id
}

output "namespace_name" {
  value = azurerm_servicebus_namespace.main.name
}

output "namespace_fqdn" {
  value = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

# Alias of namespace_fqdn for consumers that expect this name.
output "namespace_hostname" {
  value = "${azurerm_servicebus_namespace.main.name}.servicebus.windows.net"
}

output "topic_id" {
  value = azurerm_servicebus_topic.events.id
}

output "topic_name" {
  value = azurerm_servicebus_topic.events.name
}
