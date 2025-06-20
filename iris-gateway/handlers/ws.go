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
	log.Printf("[WS] WebSocket connected for user %s (token: %s). Total WS for user: %d\n", sess.Username, token, len(sess.WebSockets))

	// Send initial state including full channel history upon connection.
	sess.Mutex.RLock()
	channelsPayload := make(map[string]*session.ChannelState)
	for name, channelState := range sess.Channels {
		messages := channelState.GetMessages()
		channelsPayload[name] = &session.ChannelState{
			Name:       channelState.Name,
			Members:    channelState.Members,
			Messages:   messages,
			LastUpdate: channelState.LastUpdate,
			Topic:      channelState.Topic,
		}
		log.Printf("[WS] Preparing initial state for channel '%s' with %d messages for user %s.", name, len(messages), sess.Username)
	}
	sess.Mutex.RUnlock()

	// Send the comprehensive initial state to the newly connected client.
	err = conn.WriteJSON(events.WsEvent{
		Type: "initial_state",
		Payload: map[string]interface{}{
			"message":  fmt.Sprintf("Connected to IRIS as %s", sess.Username),
			"username": sess.Username,
			"time":     time.Now().Format(time.RFC3339),
			"channels": channelsPayload, // This payload now contains the full history for all channels.
		},
	})
	if err != nil {
		log.Printf("[WS] Error sending initial_state to %s: %v", sess.Username, err)
	}

	// NEW: Once the initial state is sent, mark the session as fully synced.
	// This signals that it can now receive real-time broadcasts.
	sess.SetSyncing(false)

	// Reader goroutine: continuously read messages from the client
	go func() {
		defer func() {
			sess.RemoveWebSocket(conn)
			conn.Close()
			log.Printf("[WS] WebSocket disconnected for user %s (token: %s)\n", sess.Username, token)
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
									ircLine = " "
								}
								log.Printf("[WS] Sending IRC line to channel %s from %s: '%s'", channelName, sess.Username, ircLine)
								sess.IRC.Privmsg(channelName, ircLine)
								time.Sleep(100 * time.Millisecond)
							}
						} else {
							log.Printf("[WS] Received malformed 'message' payload from %s: %v", sess.Username, payload)
						}
					} else {
						log.Printf("[WS] Invalid payload structure in 'message' from %s", sess.Username)
					}
				} else {
					// For other event types, we can still use a broadcast mechanism,
					// but it should be called on the session.
					sess.Broadcast(clientMsg.Type, clientMsg.Payload)
				}
			} else {
				log.Printf("[WS] Failed to unmarshal incoming message from %s: %v", sess.Username, err)
			}
		}
	}()
}