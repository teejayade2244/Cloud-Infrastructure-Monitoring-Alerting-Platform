resource "azurerm_servicebus_namespace" "main" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = var.sku
  tags                = var.tags
}

resource "azurerm_servicebus_topic" "events" {
  name                  = var.topic_name
  namespace_id          = azurerm_servicebus_namespace.main.id
  max_size_in_megabytes = var.topic_max_size_mb
  default_message_ttl   = var.topic_default_ttl
}

resource "azurerm_servicebus_subscription" "create_incident" {
  name               = "create-incident"
  topic_id           = azurerm_servicebus_topic.events.id
  max_delivery_count = var.subscription_max_delivery_count
}

resource "azurerm_servicebus_subscription" "logic_app_notifications" {
  name               = "logic-app-notifications"
  topic_id           = azurerm_servicebus_topic.events.id
  max_delivery_count = var.subscription_max_delivery_count
}

resource "azurerm_role_assignment" "events_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = var.sender_principal_id
}

resource "azurerm_role_assignment" "functions_receiver" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = var.receiver_principal_id
}
