package events

import (
    "log"

	"iris-gateway/session"
)

// WsEvent struct matches the Flutter client's expected event format
type WsEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// A global channel for messages to be broadcast to all connected clients.
// Events are sent to this channel from anywhere in your backend (e.g., IRC handlers).
var globalBroadcastChannel = make(chan WsEvent, 100) // Buffered channel to prevent blocking senders

// init function runs once when the package is imported
func init() {
	// Start the WebSocket broadcaster in a goroutine
	go startWebSocketBroadcaster()

	// --- TEMPORARY: Optional Simulation for testing if needed after the cycle fix ---
	// You can uncomment this block for testing if you want, but remove it in production.
	/*
	go func() {
		time.Sleep(5 * time.Second) // Give clients time to connect
		log.Println("[EVENTS Sim] Sending #new_channel_join")
		globalBroadcastChannel <- WsEvent{
			Type:    "channel_join",
			Payload: map[string]string{"name": "#new_channel_from_events"},
		}

		time.Sleep(10 * time.Second)
		log.Println("[EVENTS Sim] Sending #test_part_from_events")
		globalBroadcastChannel <- WsEvent{
			Type:    "channel_part",
			Payload: map[string]string{"name": "#test_from_events"},
		}

		time.Sleep(15 * time.Second)
		log.Println("[EVENTS Sim] Sending #general_message_from_events")
		globalBroadcastChannel <- WsEvent{
			Type: "message",
			Payload: map[string]string{
				"channel_name": "#general",
				"sender":       "EventsSim",
				"text":         "This is a message from the events simulator!",
			},
		}
	}()
	*/
	// --- End TEMPORARY Simulation ---
}

// startWebSocketBroadcaster listens for messages on the globalBroadcastChannel
// and forwards them to all active WebSocket connections across all user sessions.
func startWebSocketBroadcaster() {
	for {
		event := <-globalBroadcastChannel // Blocks until an event is sent
		log.Printf("[Events Broadcaster] Received event for broadcast: Type=%s, Payload=%v", event.Type, event.Payload)

		// Iterate over all active sessions and broadcast the event to their WebSockets
		session.ForEachSession(func(sess *session.UserSession) {
			// Each session's Broadcast method handles sending to its specific WebSockets
			sess.Broadcast(event.Type, event.Payload)
		})
	}
}

// Public function to allow other packages to send events
func SendEvent(eventType string, payload interface{}) {
	globalBroadcastChannel <- WsEvent{
		Type:    eventType,
		Payload: payload,
	}
}
