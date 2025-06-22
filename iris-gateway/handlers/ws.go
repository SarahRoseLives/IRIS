// handlers/ws.go

package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"iris-gateway/events"
	"iris-gateway/session"
)

// Define the WebSocket upgrader
var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow all origins for development
	},
}

// WsEvent struct matches the Flutter client's expected event format
type WsEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// WebSocketHandler handles the initial WebSocket connection upgrade and
// manages the lifecycle of the connection, including sending/receiving messages.
func WebSocketHandler(c *gin.Context) {
	token := c.Param("token")
	sess, ok := session.GetSession(token)
	if !ok {
		log.Printf("[WS] Unauthorized access attempt with token: %s", token)
		c.Writer.WriteHeader(http.StatusUnauthorized)
		c.Writer.Write([]byte("Unauthorized: Invalid session token"))
		return
	}

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("[WS] WebSocket upgrade failed for user %s (token %s): %v", sess.Username, token, err)
		return
	}

	sess.AddWebSocket(conn)
	log.Printf("[WS] WebSocket connected for user %s (token: %s)", sess.Username, token)

	// Immediately remove away status (send /BACK) when any WebSocket connects
	if sess.IRC != nil && sess.IsAway {
		sess.SetBack()
		log.Printf("[IRC] User %s reconnected, sent BACK command.", sess.Username)
	}

	// Send welcome message
	err = conn.WriteJSON(events.WsEvent{
		Type: "connected",
		Payload: map[string]interface{}{
			"message":  fmt.Sprintf("Connected to IRIS as %s", sess.Username),
			"username": sess.Username,
			"time":     time.Now().Format(time.RFC3339),
		},
	})
	if err != nil {
		log.Printf("[WS] Error sending connected message to %s: %v", sess.Username, err)
	}

	// --- FIX FOR HISTORY ---
	// Instead of sending a single 'initial_state', we send two types of events.
	// 1. Send 'restore_state'. The client uses this to trigger an API call to get the channel list, which does NOT wipe history.
	// 2. Send a series of 'members_update' events. The client handles these safely, updating each channel's member list without wiping history.

	sess.Mutex.RLock()
	channelsPayload := sess.Channels
	sess.Mutex.RUnlock()

	// Send 'restore_state' first to trigger client's channel list fetch.
	err = conn.WriteJSON(events.WsEvent{
		Type: "restore_state",
		Payload: map[string]interface{}{
			"channels": channelsPayload,
		},
	})
	if err != nil {
		log.Printf("[WS] Error sending restore_state to %s: %v", sess.Username, err)
	}

	// Now, send the member lists using the non-destructive 'members_update' event for each channel.
	go func() {
		// Wait a moment for the client to process the restore_state and fetch the channel list
		time.Sleep(500 * time.Millisecond)

		sess.Mutex.RLock()
		defer sess.Mutex.RUnlock()

		for _, channelState := range sess.Channels {
			// Create a copy inside the loop to avoid data races with the payload map
			chState := channelState
			payload := map[string]interface{}{
				"channel_name": chState.Name,
				"members":      chState.Members,
			}
			memberUpdateMsg := events.WsEvent{
				Type:    "members_update",
				Payload: payload,
			}
			if err := conn.WriteJSON(memberUpdateMsg); err != nil {
				log.Printf("[WS] Error sending members_update for %s to %s: %v", chState.Name, sess.Username, err)
			}
			// Small delay between each update
			time.Sleep(100 * time.Millisecond)
		}
		log.Printf("[WS] Finished sending all initial member_updates to %s.", sess.Username)
	}()

	go func() {
		defer func() {
			// On disconnect, remove websocket and check if last one
			sess.RemoveWebSocket(conn)
			conn.Close()
			log.Printf("[WS] WebSocket disconnected for user %s (token: %s)\n", sess.Username, token)

			// Use a small delay to prevent rapid away/back toggling on reconnects
			time.Sleep(2 * time.Second)

			// If no more WebSockets are connected, set the user as away.
			if !sess.IsActive() && sess.IRC != nil {
				sess.SetAway("IRSI") // Set a default away message
				log.Printf("[IRC] Sent AWAY command for %s (no more clients connected)", sess.Username)
			}
		}()

		for {
			messageType, p, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
					log.Printf("[WS] Client %s disconnected gracefully: %v", sess.Username, err)
				} else {
					log.Printf("[WS] Error reading message from client %s: %v", sess.Username, err)
				}
				break
			}

			log.Printf("[WS] Received message from %s: %s (Type: %d)", sess.Username, string(p), messageType)

			var clientMsg events.WsEvent
			if err := json.Unmarshal(p, &clientMsg); err == nil {
				if clientMsg.Type == "message" {
					if payload, ok := clientMsg.Payload.(map[string]interface{}); ok {
						channelName, channelOk := payload["channel_name"].(string)
						text, textOk := payload["text"].(string)

						if channelOk && textOk {
							lines := strings.Split(text, "\n")
							for _, line := range lines {
								ircLine := line
								if len(ircLine) == 0 {
									// Sending an empty line might not be supported, send a space instead
									ircLine = " "
								}
								log.Printf("[WS] Sending IRC line to channel %s from %s: '%s'", channelName, sess.Username, ircLine)
								sess.IRC.Privmsg(channelName, ircLine)
								// Add a small delay to prevent being kicked for flooding
								time.Sleep(100 * time.Millisecond)
							}
						} else {
							log.Printf("[WS] Received malformed 'message' payload from %s: %v", sess.Username, payload)
						}
					} else {
						log.Printf("[WS] Invalid payload structure in 'message' from %s", sess.Username)
					}
				} else {
					// Handle other event types like 'history' request, etc.
					log.Printf("[WS] Received unhandled event type '%s' from %s", clientMsg.Type, sess.Username)
				}
			} else {
				log.Printf("[WS] Failed to unmarshal incoming message from %s: %v", sess.Username, err)
			}
		}
	}()
}