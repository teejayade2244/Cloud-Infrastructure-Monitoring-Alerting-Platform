subscription_id        = "76736ba2-9670-4b91-81d2-38a0275ded46"
tenant_id              = "1b0eebeb-0722-47f9-8d4f-b8ed659bb53c"
client_id              = "3abb3608-c205-4047-80d5-c9407c8da8da"
publisher_email        = "teejay4125@outlook.com"
current_user_object_id = "7d131e76-7ba6-4baa-9a19-fea5d028d760"
environment            = "dev"
location               = "uksouth"
project                = "inframonitor"
create_apim            = false

# we set public_network_access_enabled = false on both Cosmos DB and Key Vault. That means ALL public traffic is blocked 
# When Terraform runs it needs to:
# Write secrets to Key Vault (cosmos-endpoint, servicebus-namespace)
# Create Cosmos DB databases and containers

# If public access is fully disabled, Terraform can't reach these services from your laptop and the apply will fail with a connection error.
# The IP allowlist is a temporary exception — it says "block everyone EXCEPT this specific IP address".
keyvault_allowed_ip_ranges = ["82.11.47.6/32"]
cosmos_allowed_ip_ranges   = ["82.11.47.6/32"]
