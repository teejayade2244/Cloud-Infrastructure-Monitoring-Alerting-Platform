Resource Group

infra-monitor-rg — UK South

Container Registry

inframonitoracr — stores all service images

Cosmos DB

Account: inframonitor-cosmos
Database: InfraMonitorDB
Containers:

Events — partition key /environment
Incidents — partition key /severity
Notifications — partition key /type



Service Bus

Namespace: inframonitorsb3443 — Standard tier
Topic: infrastructure-events
Subscriptions:

create-incident
send-notification



Key Vault

inframonitor-kv — stores all secrets

Container Apps

Environment: infra-monitor-env

APIM

inframonitor-apim — Developer tier (still provisioning)