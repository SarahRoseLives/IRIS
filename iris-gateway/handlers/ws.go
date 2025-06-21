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

	// Send current channel state to client for restoration
	sess.Mutex.RLock()
	channels := make([]string, 0, len(sess.Channels))
	for channel := range sess.Channels {
		channels = append(channels, channel)
	}
	sess.Mutex.RUnlock()

	err = conn.WriteJSON(events.WsEvent{
		Type: "restore_state",
		Payload: map[string]interface{}{
			"channels": channels,
		},
	})
	if err != nil {
		log.Printf("[WS] Error sending initial state to %s: %v", sess.Username, err)
	}

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
				// Handle restore_state from client (for multi-client/channel sync)
				if clientMsg.Type == "restore_state" {
					if payload, ok := clientMsg.Payload.(map[string]interface{}); ok {
						if chs, ok := payload["channels"].([]interface{}); ok {
							channels := make([]string, 0)
							for _, ch := range chs {
								if chstr, ok := ch.(string); ok {
									channels = append(channels, chstr)
								}
							}
							// Optionally: sess.SyncChannels(channels) if you want to reconcile state
							log.Printf("[WS] Client %s sent restore_state with channels: %v", sess.Username, channels)
						}
					}
				} else if clientMsg.Type == "message" {
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
					// For other event types, use a broadcast mechanism
					sess.Broadcast(clientMsg.Type, clientMsg.Payload)
				}
			} else {
				log.Printf("[WS] Failed to unmarshal incoming message from %s: %v", sess.Username, err)
			}
		}
	}()
}
