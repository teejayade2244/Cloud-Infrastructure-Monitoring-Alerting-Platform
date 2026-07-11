resource "azurerm_api_management" "main" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.sku_name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# --- Events API ---

resource "azurerm_api_management_api" "events" {
  name                  = "events-api"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "Events API"
  path                  = "events-api"
  protocols             = ["https"]
  subscription_required = true
}

resource "azurerm_api_management_backend" "events" {
  name                = "events-backend"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = var.events_service_url
}

resource "azurerm_api_management_api_operation" "events_health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.events.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

resource "azurerm_api_management_api_operation" "events_get" {
  operation_id        = "get-events"
  api_name            = azurerm_api_management_api.events.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Get Events"
  method              = "GET"
  url_template        = "/events"
}

resource "azurerm_api_management_api_operation" "events_post" {
  operation_id        = "post-events"
  api_name            = azurerm_api_management_api.events.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Publish Event"
  method              = "POST"
  url_template        = "/events"
}

resource "azurerm_api_management_api_policy" "events" {
  api_name            = azurerm_api_management_api.events.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${azurerm_api_management_backend.events.name}" />
    <rate-limit calls="100" renewal-period="60" />
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>${var.frontdoor_url}</origin>
        <origin>${var.frontend_url}</origin>
        <origin>http://localhost:5173</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>Content-Type</header>
        <header>Ocp-Apim-Subscription-Key</header>
      </allowed-headers>
    </cors>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <set-header name="X-Gateway" exists-action="override">
      <value>${azurerm_api_management.main.name}</value>
    </set-header>
    <set-header name="X-Powered-By" exists-action="delete" />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
XML
}

# --- Incidents API ---

resource "azurerm_api_management_api" "incidents" {
  name                  = "incidents-api"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "Incidents API"
  path                  = "incidents-api"
  protocols             = ["https"]
  subscription_required = true
}

resource "azurerm_api_management_backend" "incidents" {
  name                = "incidents-backend"
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = var.incidents_service_url
}

resource "azurerm_api_management_api_operation" "incidents_health" {
  operation_id        = "get-health"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Health Check"
  method              = "GET"
  url_template        = "/health"
}

resource "azurerm_api_management_api_operation" "incidents_get" {
  operation_id        = "get-incidents"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Get Incidents"
  method              = "GET"
  url_template        = "/incidents"
}

resource "azurerm_api_management_api_operation" "incidents_post" {
  operation_id        = "post-incidents"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Create Incident"
  method              = "POST"
  url_template        = "/incidents"
}

resource "azurerm_api_management_api_operation" "incidents_get_by_id" {
  operation_id        = "get-incident-by-id"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Get Incident by ID"
  method              = "GET"
  url_template        = "/incidents/{id}"

  template_parameter {
    name     = "id"
    type     = "string"
    required = true
  }
}

resource "azurerm_api_management_api_operation" "incidents_patch" {
  operation_id        = "patch-incident"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Update Incident"
  method              = "PATCH"
  url_template        = "/incidents/{id}"

  template_parameter {
    name     = "id"
    type     = "string"
    required = true
  }
}

resource "azurerm_api_management_api_operation" "incidents_notifications" {
  operation_id        = "get-notifications"
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  display_name        = "Get Notifications"
  method              = "GET"
  url_template        = "/notifications"
}

resource "azurerm_api_management_api_policy" "incidents" {
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="${azurerm_api_management_backend.incidents.name}" />
    <rate-limit calls="100" renewal-period="60" />
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>${var.frontdoor_url}</origin>
        <origin>${var.frontend_url}</origin>
        <origin>http://localhost:5173</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>PATCH</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>Content-Type</header>
        <header>Ocp-Apim-Subscription-Key</header>
      </allowed-headers>
    </cors>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
    <set-header name="X-Gateway" exists-action="override">
      <value>${azurerm_api_management.main.name}</value>
    </set-header>
    <set-header name="X-Powered-By" exists-action="delete" />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
XML
}

# PATCH /incidents/{id} needs Content-Type forced to application/json - overrides whatever
# the caller sends, since Container Apps' PATCH handler only accepts JSON merge-patch bodies.
resource "azurerm_api_management_api_operation_policy" "incidents_patch" {
  api_name            = azurerm_api_management_api.incidents.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = var.resource_group_name
  operation_id        = azurerm_api_management_api_operation.incidents_patch.operation_id

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <set-header name="Content-Type" exists-action="override">
      <value>application/json</value>
    </set-header>
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
XML
}

# --- Subscription ---
#
# No product_id/api_id set on purpose: this provider version has no "scope" argument on
# azurerm_api_management_subscription (unlike older docs/examples that reference one) - leaving
# both unset is how this resource represents an all-APIs subscription.
resource "azurerm_api_management_subscription" "main" {
  resource_group_name = var.resource_group_name
  api_management_name = azurerm_api_management.main.name
  display_name        = "InfraMonitor Subscription"
  state               = "active"
}
