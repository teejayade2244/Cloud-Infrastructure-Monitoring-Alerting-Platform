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