# Resource group
az group create --name infra-monitor-rg --location uksouth

# ACR
az acr create \
  --name inframonitoracr \
  --resource-group infra-monitor-rg \
  --sku Basic \
  --location uksouth

# Cosmos DB
az cosmosdb create \
  --name inframonitor-cosmos \
  --resource-group infra-monitor-rg \
  --locations regionName=uksouth isZoneRedundant=false

# Service Bus
az servicebus namespace create \
  --name inframonitorsb3443 \
  --resource-group infra-monitor-rg \
  --location uksouth \
  --sku Standard

# Key Vault
az keyvault create \
  --name inframonitor-kv \
  --resource-group infra-monitor-rg \
  --location uksouth


  # Cosmos DB database
az cosmosdb sql database create \
  --account-name inframonitor-cosmos \
  --resource-group infra-monitor-rg \
  --name InfraMonitorDB

# Events container
az cosmosdb sql container create \
  --account-name inframonitor-cosmos \
  --resource-group infra-monitor-rg \
  --database-name InfraMonitorDB \
  --name Events \
  --partition-key-path "/environment"

# Incidents container
az cosmosdb sql container create \
  --account-name inframonitor-cosmos \
  --resource-group infra-monitor-rg \
  --database-name InfraMonitorDB \
  --name Incidents \
  --partition-key-path "/severity"

# Notifications container
az cosmosdb sql container create \
  --account-name inframonitor-cosmos \
  --resource-group infra-monitor-rg \
  --database-name InfraMonitorDB \
  --name Notifications \
  --partition-key-path "/type"

# Service Bus topic
az servicebus topic create \
  --name infrastructure-events \
  --namespace-name inframonitorsb3443 \
  --resource-group infra-monitor-rg

# Service Bus subscriptions
az servicebus topic subscription create \
  --name create-incident \
  --topic-name infrastructure-events \
  --namespace-name inframonitorsb3443 \
  --resource-group infra-monitor-rg \
  --max-delivery-count 3

az servicebus topic subscription create \
  --name send-notification \
  --topic-name infrastructure-events \
  --namespace-name inframonitorsb3443 \
  --resource-group infra-monitor-rg \
  --max-delivery-count 3

az containerapp env create \
  --name infra-monitor-env \
  --resource-group infra-monitor-rg \
  --location uksouth

az apim create \
  --name inframonitor-apim \
  --resource-group infra-monitor-rg \
  --location uksouth \
  --publisher-name "InfraMonitor" \
  --publisher-email "temitope224468574@outlook.com" \
  --sku-name Developer


  # Create managed identity for events service
az identity create \
  --name events-service-identity \
  --resource-group infra-monitor-rg

# Create managed identity for incidents service
az identity create \
  --name incidents-service-identity \
  --resource-group infra-monitor-rg

# Create managed identity for functions
az identity create \
  --name functions-identity \
  --resource-group infra-monitor-rg

# Create managed identity for go notification service
az identity create \
  --name notification-identity \
  --resource-group infra-monitor-rg


# Variables
COSMOS_ID=$(az cosmosdb show --name inframonitor-cosmos --resource-group infra-monitor-rg --query id -o tsv)
SB_ID=$(az servicebus namespace show --name inframonitorsb3443 --resource-group infra-monitor-rg --query id -o tsv)
ACR_ID=$(az acr show --name inframonitoracr --resource-group infra-monitor-rg --query id -o tsv)
KV_ID=$(az keyvault show --name inframonitor-kv --resource-group infra-monitor-rg --query id -o tsv)

# Events service - needs Cosmos write + Service Bus send + ACR pull
az cosmosdb sql role assignment create --account-name inframonitor-cosmos --resource-group infra-monitor-rg --scope "/" --principal-id 07b0b8ec-1131-4dcd-b45d-756ad6793bfe --role-definition-id 00000000-0000-0000-0000-000000000002

az role assignment create --assignee 07b0b8ec-1131-4dcd-b45d-756ad6793bfe --role "Azure Service Bus Data Sender" --scope $SB_ID

az role assignment create --assignee 07b0b8ec-1131-4dcd-b45d-756ad6793bfe --role AcrPull --scope $ACR_ID

# Incidents service - needs Cosmos read/write + ACR pull
az cosmosdb sql role assignment create --account-name inframonitor-cosmos --resource-group infra-monitor-rg --scope "/" --principal-id e16dad35-7e18-427a-8b28-f1ce52da4a71 --role-definition-id 00000000-0000-0000-0000-000000000002

az role assignment create --assignee e16dad35-7e18-427a-8b28-f1ce52da4a71 --role AcrPull --scope $ACR_ID

# Functions identity - needs Cosmos write + Service Bus receive + ACR pull
az cosmosdb sql role assignment create --account-name inframonitor-cosmos --resource-group infra-monitor-rg --scope "/" --principal-id 5f4a836f-797b-48cd-8e49-198cda8a99be --role-definition-id 00000000-0000-0000-0000-000000000002

az role assignment create --assignee 5f4a836f-797b-48cd-8e49-198cda8a99be --role "Azure Service Bus Data Receiver" --scope $SB_ID

az role assignment create --assignee 5f4a836f-797b-48cd-8e49-198cda8a99be --role AcrPull --scope $ACR_ID

# Notification service (Go) - needs Cosmos write + Service Bus receive + ACR pull
az cosmosdb sql role assignment create --account-name inframonitor-cosmos --resource-group infra-monitor-rg --scope "/" --principal-id d6d8f03f-6606-40db-8517-d85356fdc04e --role-definition-id 00000000-0000-0000-0000-000000000002

az role assignment create --assignee d6d8f03f-6606-40db-8517-d85356fdc04e --role "Azure Service Bus Data Receiver" --scope $SB_ID

az role assignment create --assignee d6d8f03f-6606-40db-8517-d85356fdc04e --role AcrPull --scope $ACR_ID

# All identities need Key Vault read
az role assignment create --assignee 07b0b8ec-1131-4dcd-b45d-756ad6793bfe --role "Key Vault Secrets User" --scope $KV_ID
az role assignment create --assignee e16dad35-7e18-427a-8b28-f1ce52da4a71 --role "Key Vault Secrets User" --scope $KV_ID
az role assignment create --assignee 5f4a836f-797b-48cd-8e49-198cda8a99be --role "Key Vault Secrets User" --scope $KV_ID
az role assignment create --assignee d6d8f03f-6606-40db-8517-d85356fdc04e --role "Key Vault Secrets User" --scope $KV_ID