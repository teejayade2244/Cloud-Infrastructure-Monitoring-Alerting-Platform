Events Service      → Node.js    (you just wrote this)
Incidents Service   → .NET C#    (next to build)
CreateIncident Fn   → .NET C#    (same codebase as Incidents Service)
SendNotification Fn → Go         (separate lightweight function)

1. CI/CD pipeline deploys new version → calls Events Service via APIM
2. Events Service validates JWT token, stores event in Cosmos DB
3. Events Service publishes to Service Bus topic
4. CreateIncident Function triggers → creates incident in Cosmos DB
5. SendNotification Function triggers → logs alert
6. Engineer calls Incidents Service via APIM to update incident status
7. Incident resolved → resolution event published → notification fired

Cloud Infrastructure Monitoring & Alerting Platform

The Problem it solves:
In a real engineering team, when something goes wrong — a deployment fails, a service goes down, CPU spikes — engineers need to know immediately, track what happened, assign someone to fix it, and have a record of everything. Right now you've been learning individual Azure services in isolation. This project wires them all together into something that solves a real operational problem.

The Architecture:
Engineer/System → APIM Gateway → Microservices → Data & Messaging
                                                → Alerts & Notifications
Three core microservices:
1. Events Service — the entry point. Receives infrastructure events from any source — a deployment pipeline, a monitoring agent, a developer manually reporting something. Stores events in Cosmos DB and publishes to Service Bus.
2. Incidents Service — when a critical event comes in, an incident is automatically created. Engineers can update incident status (open, investigating, resolved). Full audit trail in Cosmos DB.
3. Notifications Service — an Azure Function that listens to Service Bus. When a critical incident is created it fires an alert. In a real system this would send Slack/email — we'll log it and store in Cosmos DB.

How the Azure services map to real responsibilities:
APIM — single gateway for all three services. Subscription keys for API consumers (your monitoring agents, CI/CD pipelines). JWT validation via Entra ID. Rate limiting so a noisy monitoring agent can't flood the platform.
Container Apps — Events Service and Incidents Service deployed here. Internal service-to-service communication via Dapr (which you already know). External ingress only through APIM.
Cosmos DB — stores events, incidents and notifications. NoSQL fits perfectly — events are semi-structured, each has different properties depending on type.
Service Bus Topic — Events Service publishes every critical event here. Two subscriptions: one for the Incidents Function (creates incident), one for the Notifications Function (fires alert).
Azure Functions — two functions triggered by Service Bus:

CreateIncident — receives critical event, creates incident record in Cosmos DB
SendNotification — receives critical event, logs alert, stores notification record

Key Vault — Cosmos DB connection details, Service Bus connection string. All services fetch via managed identity.
App Configuration — feature flags (enable-auto-incident-creation, enable-notifications), environment settings (alert-threshold-cpu, alert-threshold-memory).
Managed Identity — every service authenticates to every other Azure resource without a single hardcoded credential.
ACR — stores container images for Events Service and Incidents Service.


Client → APIM → Events Service → Cosmos DB (event)
                              → Service Bus (critical only)
                                    ↓
                    CreateIncident Function → Cosmos DB (incident)
                    SendNotification Function → Cosmos DB (notification)

Client → APIM → Incidents Service → Cosmos DB (read/update incidents)