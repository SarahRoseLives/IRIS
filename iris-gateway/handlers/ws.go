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

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		return true // Allow all origins
	},
}

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
	log.Printf("[WS] WebSocket connected for user %s (token: %s). Total devices: %d", sess.Username, token, len(sess.WebSockets))

	if sess.IRC != nil && sess.IsAway {
		sess.SetBack()
		log.Printf("[IRC] User %s reconnected, sent BACK command.", sess.Username)
	}

	sess.Mutex.RLock()
	initialStatePayload := gin.H{
		"channels": sess.Channels,
	}
	sess.Mutex.RUnlock()

	sess.WsMutex.Lock()
	err = conn.WriteJSON(events.WsEvent{
		Type:    "initial_state",
		Payload: initialStatePayload,
	})
	sess.WsMutex.Unlock()

	if err != nil {
		log.Printf("[WS] Error sending initial_state to %s: %v", sess.Username, err)
		sess.RemoveWebSocket(conn)
		conn.Close()
		return
	}
	log.Printf("[WS] Sent initial_state payload to %s.", sess.Username)

	go func() {
		defer func() {
			// On disconnect, remove the websocket from the session
			sess.RemoveWebSocket(conn)

			// --- ADDED CHANGE: Clean up the token for this disconnected device ---
			// This prevents the session map from growing with stale tokens.
			session.UnmapToken(token)

			conn.Close()
			log.Printf("[WS] WebSocket disconnected for user %s (token: %s). Remaining devices: %d\n", sess.Username, token, len(sess.WebSockets))

			// Use a small delay to prevent rapid away/back toggling on reconnects
			time.Sleep(2 * time.Second)

			// If no more WebSockets are connected for this session, set the user as away.
			if !sess.IsActive() && sess.IRC != nil {
				sess.SetAway("IRSI")
				log.Printf("[IRC] Sent AWAY command for %s (no more clients connected)", sess.Username)
			}
		}()

		for {
			messageType, p, err := conn.ReadMessage()
			if err != nil {
				if websocket.IsCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure, 1006) {
					log.Printf("[WS] Client %s disconnected gracefully: %v", sess.Username, err)
				} else {
					log.Printf("[WS] Error reading message from client %s: %v", sess.Username, err)
				}
				break
			}

			log.Printf("[WS] Received message from %s: %s (Type: %d)", sess.Username, string(p), messageType)

			var clientMsg events.WsEvent
			if err := json.Unmarshal(p, &clientMsg); err != nil {
				log.Printf("[WS] Failed to unmarshal incoming message from %s: %v", sess.Username, err)
				continue
			}

			switch clientMsg.Type {
			case "message":
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

			case "topic_change":
				if payload, ok := clientMsg.Payload.(map[string]interface{}); ok {
					channel, chanOk := payload["channel"].(string)
					newTopic, topicOk := payload["topic"].(string)

					if chanOk && topicOk {
						if sess.IRC != nil {
							log.Printf("[WS] User %s sending TOPIC command for channel %s", sess.Username, channel)
							sess.IRC.SendRaw(fmt.Sprintf("TOPIC %s :%s", channel, newTopic))
						}
					} else {
						log.Printf("[WS] Received malformed 'topic_change' payload from %s: %v", sess.Username, payload)
					}
				} else {
					log.Printf("[WS] Invalid payload structure in 'topic_change' from %s", sess.Username)
				}

			default:
				log.Printf("[WS] Received unhandled event type '%s' from %s", clientMsg.Type, sess.Username)
			}
		}
	}()
}