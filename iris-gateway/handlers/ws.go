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
	"iris-gateway/irc" // Used for adding messages to history
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

	// If the user has reconnected and was away, send BACK to all connected networks
	if sess.IsAway {
		sess.SetBack()
		log.Printf("[IRC] User %s reconnected, sent BACK command to all networks.", sess.Username)
	}

	// Send initial state including all configured networks and their channels/members
	initialStatePayload := gin.H{
		"networks": make([]map[string]interface{}, 0),
	}
	sess.Mutex.RLock()
	for _, netConfig := range sess.Networks {
		netConfig.Mutex.RLock() // Lock the network config for reading
		networkInfo := map[string]interface{}{
			"id":             netConfig.ID,
			"network_name":   netConfig.NetworkName,
			"is_connected":   netConfig.IsConnected,
			"channels":       make([]map[string]interface{}, 0),
		}
		for _, ch := range netConfig.Channels {
			ch.Mutex.RLock() // Lock the channel state for reading
			networkInfo["channels"] = append(networkInfo["channels"].([]map[string]interface{}), map[string]interface{}{
				"name":        ch.Name,
				"topic":       ch.Topic,
				"members":     ch.Members,
				"last_update": ch.LastUpdate,
			})
			ch.Mutex.RUnlock() // Unlock channel state
		}
		netConfig.Mutex.RUnlock() // Unlock network config
		initialStatePayload["networks"] = append(initialStatePayload["networks"].([]map[string]interface{}), networkInfo)
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
			sess.RemoveWebSocket(conn)
			conn.Close()
			log.Printf("[WS] WebSocket disconnected for user %s (token: %s). Remaining devices: %d\n", sess.Username, token, len(sess.WebSockets))

			time.Sleep(2 * time.Second) // Small delay to prevent rapid away/back toggling

			// If no more WebSockets are connected for this session, set the user as away.
			if !sess.IsActive() {
				sess.SetAway("Client disconnected.") // Will send AWAY to all connected IRC networks
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
					networkIDFloat, idOk := payload["network_id"].(float64) // JSON numbers are float64
					channelName, channelOk := payload["channel_name"].(string)
					text, textOk := payload["text"].(string)

					if idOk && channelOk && textOk {
						networkID := int(networkIDFloat)
						netConfig, foundNet := sess.GetNetwork(networkID)
						if !foundNet || netConfig.IRC == nil || !netConfig.IsConnected {
							log.Printf("[WS] Cannot send message: Network %d not connected or found for user %s.", networkID, sess.Username)
							// Optionally, send an error back to the client
							sess.Broadcast("error", map[string]string{"message": fmt.Sprintf("Network %s is not connected.", netConfig.NetworkName), "network_id": fmt.Sprintf("%d", networkID)})
							continue
						}

						lines := strings.Split(text, "\n")
						for _, line := range lines {
							ircLine := line
							if len(ircLine) == 0 {
								ircLine = " "
							}
							log.Printf("[WS] Sending IRC line to channel %s on network %s from %s: '%s'", channelName, netConfig.NetworkName, sess.Username, ircLine)
							netConfig.IRC.Privmsg(channelName, ircLine)

							// Add message to history
							msgToStore := irc.Message{
								NetworkID: networkID,
								Channel:   channelName,
								Sender:    netConfig.Nickname, // Use the user's nickname for this network
								Text:      ircLine,
								Timestamp: time.Now(),
							}
							irc.AddMessageToHistory(networkID, channelName, msgToStore)

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
					networkIDFloat, idOk := payload["network_id"].(float64)
					channel, chanOk := payload["channel"].(string)
					newTopic, topicOk := payload["topic"].(string)

					if idOk && chanOk && topicOk {
						networkID := int(networkIDFloat)
						netConfig, foundNet := sess.GetNetwork(networkID)
						if !foundNet || netConfig.IRC == nil || !netConfig.IsConnected {
							log.Printf("[WS] Cannot change topic: Network %d not connected or found for user %s.", networkID, sess.Username)
							sess.Broadcast("error", map[string]string{"message": fmt.Sprintf("Network %s is not connected.", netConfig.NetworkName), "network_id": fmt.Sprintf("%d", networkID)})
							continue
						}
						log.Printf("[WS] User %s sending TOPIC command for channel %s on network %s", sess.Username, channel, netConfig.NetworkName)
						netConfig.IRC.SendRaw(fmt.Sprintf("TOPIC %s :%s", channel, newTopic))
					} else {
						log.Printf("[WS] Received malformed 'topic_change' payload from %s: %v", sess.Username, payload)
					}
				} else {
					log.Printf("[WS] Invalid payload structure in 'topic_change' from %s", sess.Username)
				}
				// Add more client-to-server commands here as needed (e.g., /away, /nick, /quit)

			default:
				log.Printf("[WS] Received unhandled event type '%s' from %s", clientMsg.Type, sess.Username)
			}
		}
	}()
}