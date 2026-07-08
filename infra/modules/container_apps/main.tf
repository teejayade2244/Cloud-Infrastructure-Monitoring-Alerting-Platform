resource "azurerm_container_app_environment" "main" {
  name                           = var.environment_name
  location                       = var.location
  resource_group_name            = var.resource_group_name
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  infrastructure_subnet_id       = var.apps_subnet_id
  internal_load_balancer_enabled = false
  tags                           = var.tags

  # Azure always maintains a baseline "Consumption" workload profile on Container Apps
  # environments now, regardless of what's declared here. Without this block, every plan
  # after apply kept trying (and failing) to remove it - declaring it explicitly makes the
  # desired state match what Azure actually enforces, so plans converge to zero changes.
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }
}

resource "azurerm_container_app" "events" {
  name                         = "events-service-dev"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.events_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.events_identity_id
  }

  secret {
    name                = "cosmos-endpoint"
    key_vault_secret_id = var.cosmos_endpoint_secret_id
    identity            = var.events_identity_id
  }

  secret {
    name                = "servicebus-namespace"
    key_vault_secret_id = var.servicebus_namespace_secret_id
    identity            = var.events_identity_id
  }

  secret {
    name                = "appinsights-connection-string"
    key_vault_secret_id = var.appinsights_connection_string_secret_id
    identity            = var.events_identity_id
  }

  ingress {
    external_enabled = true
    target_port      = 3000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 5

    container {
      name   = "events-service"
      image  = "${var.acr_login_server}/${var.events_service_image}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "COSMOS_ENDPOINT"
        secret_name = "cosmos-endpoint"
      }

      env {
        name        = "SERVICEBUS_NAMESPACE"
        secret_name = "servicebus-namespace"
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = var.events_identity_client_id
      }

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

resource "azurerm_container_app" "incidents" {
  name                         = "incidents-service-dev"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.incidents_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.incidents_identity_id
  }

  secret {
    name                = "cosmos-endpoint"
    key_vault_secret_id = var.cosmos_endpoint_secret_id
    identity            = var.incidents_identity_id
  }

  secret {
    name                = "appinsights-connection-string"
    key_vault_secret_id = var.appinsights_connection_string_secret_id
    identity            = var.incidents_identity_id
  }

  ingress {
    external_enabled = true
    target_port      = 3000

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    min_replicas = 1
    max_replicas = 5

    container {
      name   = "incidents-service"
      image  = "${var.acr_login_server}/${var.incidents_service_image}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AZURE_CLIENT_ID"
        value = var.incidents_identity_client_id
      }

      env {
        name        = "COSMOS_ENDPOINT"
        secret_name = "cosmos-endpoint"
      }

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

# CreateIncident replaces what would otherwise be an Azure Function - the subscription can't
# create App Service Plans right now (see main.tf), so this runs as a KEDA-scaled Container Apps
# Job instead, triggered by Service Bus subscription depth. (SendNotification was removed - the
# Logic App now handles all notification processing.)
#
# Scale rule auth uses identity_id (the functions-identity user-assigned identity), not a
# connection-string secret - KEDA's azure-servicebus scaler supports AAD/workload-identity auth
# directly, and functions-identity already holds "Azure Service Bus Data Receiver" on the
# namespace (granted in the servicebus module), which is sufficient for KEDA to read
# subscription message counts. This avoids reintroducing shared-key/connection-string auth into
# an otherwise fully managed-identity-based architecture.
resource "azurerm_container_app_job" "create_incident" {
  name                         = "inframonitor-create-incident-dev"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = var.resource_group_name
  location                     = var.location
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  replica_timeout_in_seconds = 300
  replica_retry_limit        = 3

  identity {
    type         = "UserAssigned"
    identity_ids = [var.functions_identity_id]
  }

  registry {
    server   = var.acr_login_server
    identity = var.functions_identity_id
  }

  secret {
    name                = "cosmos-endpoint"
    key_vault_secret_id = var.cosmos_endpoint
    identity            = var.functions_identity_id
  }

  secret {
    name  = "appinsights-connection-string"
    value = var.appinsights_connection_string
  }

  event_trigger_config {
    parallelism              = 1
    replica_completion_count = 1

    scale {
      min_executions              = 0
      max_executions              = 1
      polling_interval_in_seconds = 30

      rules {
        name             = "service-bus-trigger"
        custom_rule_type = "azure-servicebus"
        identity_id      = var.functions_identity_id

        metadata = {
          topicName        = "infrastructure-events"
          subscriptionName = "create-incident"
          messageCount     = "1"
          namespace        = split(".", var.servicebus_namespace)[0]
        }
      }
    }
  }

  template {
    container {
      name    = "create-incident"
      image   = "${var.acr_login_server}/${var.incident_functions_image}"
      cpu     = 0.5
      memory  = "1Gi"
      command = ["node", "src/create-incident.js"]

      env {
        name        = "COSMOS_ENDPOINT"
        secret_name = "cosmos-endpoint"
      }

      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = var.servicebus_namespace
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = var.functions_identity_client_id
      }

      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}

