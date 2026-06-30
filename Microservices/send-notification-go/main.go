package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
	"github.com/Azure/azure-sdk-for-go/sdk/messaging/azservicebus"
)

type InfraEvent struct {
	ID          string                 `json:"id"`
	Type        string                 `json:"type"`
	Environment string                 `json:"environment"`
	Severity    string                 `json:"severity"`
	Message     string                 `json:"message"`
	Source      string                 `json:"source"`
	Metadata    map[string]interface{} `json:"metadata"`
	Timestamp   string                 `json:"timestamp"`
}

type Notification struct {
	ID          string `json:"id"`
	EventID     string `json:"eventId"`
	Type        string `json:"type"`
	Severity    string `json:"severity"`
	Message     string `json:"message"`
	Source      string `json:"source"`
	Environment string `json:"environment"`
	Channel     string `json:"channel"`
	SentAt      string `json:"sentAt"`
	Status      string `json:"status"`
}

func main() {
	log.Println("SendNotification service starting...")

	// Azure credential
	credential, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		log.Fatalf("Failed to create credential: %v", err)
	}

	// Cosmos DB client
	cosmosEndpoint := os.Getenv("COSMOS_ENDPOINT")
	cosmosClient, err := azcosmos.NewClient(cosmosEndpoint, credential, nil)
	if err != nil {
		log.Fatalf("Failed to create Cosmos client: %v", err)
	}
	container, err := cosmosClient.NewContainer("InfraMonitorDB", "Notifications")
	if err != nil {
		log.Fatalf("Failed to get container: %v", err)
	}

	// Service Bus client
	sbNamespace := os.Getenv("SERVICEBUS_NAMESPACE")
	sbClient, err := azservicebus.NewClient(sbNamespace, credential, nil)
	if err != nil {
		log.Fatalf("Failed to create Service Bus client: %v", err)
	}

	// Create receiver for send-notification subscription
	receiver, err := sbClient.NewReceiverForSubscription(
		"infrastructure-events",
		"send-notification",
		nil,
	)
	if err != nil {
		log.Fatalf("Failed to create receiver: %v", err)
	}
	defer receiver.Close(context.Background())

	log.Println("Listening for infrastructure events...")

	for {
		messages, err := receiver.ReceiveMessages(context.Background(), 10, nil)
		if err != nil {
			log.Printf("Error receiving messages: %v", err)
			time.Sleep(5 * time.Second)
			continue
		}

		for _, msg := range messages {
			var event InfraEvent
			if err := json.Unmarshal(msg.Body, &event); err != nil {
				log.Printf("Failed to parse event: %v", err)
				receiver.AbandonMessage(context.Background(), msg, nil)
				continue
			}

			notification := Notification{
				ID:          fmt.Sprintf("NOTIF-%d", time.Now().UnixMilli()),
				EventID:     event.ID,
				Type:        "alert",
				Severity:    event.Severity,
				Message:     fmt.Sprintf("🚨 %s ALERT: %s", event.Severity, event.Message),
				Source:      event.Source,
				Environment: event.Environment,
				Channel:     "platform",
				SentAt:      time.Now().UTC().Format(time.RFC3339),
				Status:      "sent",
			}

			// Save to Cosmos DB
			notifJSON, _ := json.Marshal(notification)
			pk := azcosmos.NewPartitionKeyString(notification.Type)
			_, err = container.CreateItem(context.Background(), pk, notifJSON, nil)
			if err != nil {
				log.Printf("Failed to save notification: %v", err)
				receiver.AbandonMessage(context.Background(), msg, nil)
				continue
			}

			// Log the alert
			log.Println("=================================")
			log.Printf("🚨 ALERT: %s", notification.Message)
			log.Printf("Environment: %s", event.Environment)
			log.Printf("Source: %s", event.Source)
			log.Printf("Severity: %s", event.Severity)
			log.Println("=================================")

			// Complete the message
			receiver.CompleteMessage(context.Background(), msg, nil)
			log.Printf("Notification saved: %s", notification.ID)
		}
	}
}