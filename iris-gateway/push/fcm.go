// push/fcm.go
package push

import (
	"context"
	"log"
	"fmt"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

var fcmClient *messaging.Client

func InitFCM() {
	// IMPORTANT: Make sure "serviceAccountKey.json" is in the root directory of your project.
	opt := option.WithCredentialsFile("serviceAccountKey.json")
	app, err := firebase.NewApp(context.Background(), nil, opt)
	if err != nil {
		log.Fatalf("error initializing FCM app: %v\n", err)
	}

	client, err := app.Messaging(context.Background())
	if err != nil {
		log.Fatalf("error getting FCM client: %v\n", err)
	}
	fcmClient = client
	log.Println("[FCM] Firebase Cloud Messaging initialized.")
}

// SendPushNotification sends a data-only notification to a specific device token.
// This allows the client app to handle the notification itself, which is crucial for
// background/terminated app states.
func SendPushNotification(token, title, body string, data map[string]string) error {
	if fcmClient == nil {
		log.Println("[FCM] FCM client not initialized. Skipping push notification.")
		// We return an error here to be more explicit that something is wrong.
		return fmt.Errorf("FCM client not initialized")
	}

	// 1. Combine all data into a single map. The client will use this
	//    to construct the local notification.
	if data == nil {
		data = make(map[string]string)
	}
	data["title"] = title
	data["body"] = body

	// 2. Construct a data-only message. The "Notification" field is intentionally omitted.
	message := &messaging.Message{
		Data:  data,
		Token: token,
		// 3. Add platform-specific configuration for better reliability.
		Android: &messaging.AndroidConfig{
			// Set priority to 'high' to wake a sleeping device.
			Priority: "high",
		},
		APNS: &messaging.APNSConfig{
			Payload: &messaging.APNSPayload{
				Aps: &messaging.Aps{
					// Set content-available to 1 to wake up the iOS app in the background.
					ContentAvailable: true,
				},
			},
		},
	}

	response, err := fcmClient.Send(context.Background(), message)
	if err != nil {
		log.Printf("[FCM] Error sending push notification: %v", err)
		return err
	}

	log.Printf("[FCM] Successfully sent data-only push notification: %s", response)
	return nil
}