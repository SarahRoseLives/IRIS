package handlers

import (
	"encoding/json"
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

	// --- MODIFIED: Send a single, comprehensive initial_state event ---
	// This event contains everything the client needs to restore its UI.
	sess.Mutex.RLock()
	initialStatePayload := gin.H{
		"channels": sess.Channels,
		// You could add other initial state data here, like user settings etc.
	}
	sess.Mutex.RUnlock()

	// FIX: Synchronize this write operation with the session's broadcast method
	// to prevent concurrent write errors on the websocket connection.
	sess.WsMutex.Lock()
	err = conn.WriteJSON(events.WsEvent{
		Type:    "initial_state",
		Payload: initialStatePayload,
	})
	sess.WsMutex.Unlock()

	if err != nil {
		log.Printf("[WS] Error sending initial_state to %s: %v", sess.Username, err)
		// Since we failed to send the initial state, we should close the connection.
		sess.RemoveWebSocket(conn)
		conn.Close()
		return
	}
	log.Printf("[WS] Sent initial_state payload to %s.", sess.Username)
	// --- END MODIFICATION ---

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
				if websocket.IsCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure, 1006) {
					log.Printf("[WS] Client %s disconnected gracefully or with abnormal closure: %v", sess.Username, err)
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