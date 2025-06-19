// push/fcm.go
package push

import (
	"context"
	"log"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

var fcmClient *messaging.Client

func InitFCM() {
	// IMPORTANT: Replace "path/to/your/serviceAccountKey.json" with the actual path
	// to your Firebase service account key file.
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

// SendPushNotification sends a notification to a specific device token.
func SendPushNotification(token, title, body string, data map[string]string) error {
	if fcmClient == nil {
		log.Println("[FCM] FCM client not initialized. Skipping push notification.")
		return nil
	}

	message := &messaging.Message{
		Notification: &messaging.Notification{
			Title: title,
			Body:  body,
		},
		Data:  data,
		Token: token,
	}

	response, err := fcmClient.Send(context.Background(), message)
	if err != nil {
		log.Printf("[FCM] Error sending push notification: %v", err)
		return err
	}

	log.Printf("[FCM] Successfully sent push notification: %s", response)
	return nil
}