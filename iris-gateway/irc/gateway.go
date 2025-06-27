package irc

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/events"
	"iris-gateway/push"
	"iris-gateway/session"
)

type Message struct {
	Channel   string    `json:"channel"`
	Sender    string    `json:"sender"`
	Text      string    `json:"text"`
	Timestamp time.Time `json:"timestamp"`
}

type ChannelHistory struct {
	Messages []Message
	mutex    sync.RWMutex
}

var (
	gatewayConn        *ircevent.Connection
	historyMap         = make(map[string]*ChannelHistory)
	historyMutex       sync.RWMutex
	historyDuration    = 7 * 24 * time.Hour // Default 7 days
	persistedChannels  = make(map[string]bool)
	channelsMutex      sync.RWMutex
	channelsFile       = "persisted_channels.json"
)

// Helper function for mention detection (case-insensitive, word boundary, NO @ required)
func mentionInMessage(username, text string) bool {
	pattern := fmt.Sprintf(`(?i)\b%s\b`, regexp.QuoteMeta(username))
	matched, _ := regexp.MatchString(pattern, text)
	return matched
}

// Load persisted channels from file
func loadPersistedChannels() error {
	file, err := os.ReadFile(channelsFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // File doesn't exist yet, that's fine
		}
		return err
	}

	channelsMutex.Lock()
	defer channelsMutex.Unlock()
	return json.Unmarshal(file, &persistedChannels)
}

// Save persisted channels to file
func savePersistedChannels() error {
	channelsMutex.RLock()
	defer channelsMutex.RUnlock()

	data, err := json.Marshal(persistedChannels)
	if err != nil {
		return err
	}

	return os.WriteFile(channelsFile, data, 0644)
}

// Add channel to persisted list
func persistChannel(channel string) {
	channelsMutex.Lock()
	persistedChannels[strings.ToLower(channel)] = true
	channelsMutex.Unlock()

	if err := savePersistedChannels(); err != nil {
		log.Printf("[Gateway] Failed to save persisted channels: %v", err)
	}
}

// Remove channel from persisted list
func unpersistChannel(channel string) {
	channelsMutex.Lock()
	delete(persistedChannels, strings.ToLower(channel))
	channelsMutex.Unlock()

	if err := savePersistedChannels(); err != nil {
		log.Printf("[Gateway] Failed to save persisted channels: %v", err)
	}
}

// Check if channel is persisted
func isChannelPersisted(channel string) bool {
	channelsMutex.RLock()
	defer channelsMutex.RUnlock()
	return persistedChannels[strings.ToLower(channel)]
}

// Call this once at startup (from main.go)
func InitGatewayBot() error {
	// Load persisted channels
	if err := loadPersistedChannels(); err != nil {
		log.Printf("[Gateway] Warning: Could not load persisted channels: %v", err)
	}

	// Create a dummy session for the gateway
	gatewaySession := session.NewUserSession(config.Cfg.GatewayNick)
	gatewaySession.IRC = nil // Will be set by AuthenticateWithNickServ

	clientIP := "127.0.0.1" // Gateway connects from localhost

	// Use the same authentication flow as clients
	ircConn, err := AuthenticateWithNickServ(
		config.Cfg.GatewayNick,
		config.Cfg.GatewayPassword,
		clientIP,
		gatewaySession,
	)
	if err != nil {
		return fmt.Errorf("failed to authenticate gateway bot: %w", err)
	}

	// Set up the gateway connection
	gatewayConn = ircConn
	gatewaySession.IRC = ircConn

	// Parse history duration from config
	duration, err := time.ParseDuration(config.Cfg.HistoryDuration)
	if err != nil {
		log.Printf("Invalid history duration '%s', using default 7 days", config.Cfg.HistoryDuration)
	} else {
		historyDuration = duration
	}

	ircConn.AddCallback("001", func(e *ircevent.Event) {
		log.Println("[Gateway] Connected to IRC server")
		// Join all persisted channels
		channelsMutex.RLock()
		for channel := range persistedChannels {
			log.Printf("[Gateway] Auto-joining persisted channel: %s", channel)
			ircConn.Join(channel)
		}
		channelsMutex.RUnlock()
	})

	ircConn.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		channel := e.Arguments[0]
		sender := e.Nick
		messageContent := e.Arguments[1]

		log.Printf("[Gateway] Logging message in %s from %s: %s", channel, sender, messageContent)

		message := Message{
			Channel:   channel,
			Sender:    sender,
			Text:      messageContent,
			Timestamp: time.Now(),
		}

		// History only for channels
		if strings.HasPrefix(channel, "#") {
			channelKey := strings.ToLower(channel)
			historyMutex.Lock()
			chHistory, exists := historyMap[channelKey]
			if !exists {
				chHistory = &ChannelHistory{
					Messages: make([]Message, 0),
				}
				historyMap[channelKey] = chHistory
				log.Printf("[Gateway] Created new history slice for channel: %s", channelKey)
			}
			// Lock ordering: historyMutex (outer, short) -> chHistory.mutex (inner, can be slow)
			chHistory.mutex.Lock()
			historyMutex.Unlock()

			chHistory.Messages = append(chHistory.Messages, message)
			log.Printf("[Gateway] Appended message to channel %s, total now: %d", channelKey, len(chHistory.Messages))
			log.Printf("[DEBUG] After append, %d messages in %s: last=%+v", len(chHistory.Messages), channelKey, chHistory.Messages[len(chHistory.Messages)-1])

			// Clean up old messages
			cutoff := time.Now().Add(-historyDuration)
			log.Printf("[DEBUG] Prune cutoff: %v", cutoff)
			var firstValidIndex = -1
			for i, msg := range chHistory.Messages {
				log.Printf("[DEBUG] Message %d timestamp: %v", i, msg.Timestamp)
				if msg.Timestamp.After(cutoff) {
					firstValidIndex = i
					break
				}
			}
			if firstValidIndex > 0 {
				log.Printf("[Gateway] Pruned %d old messages from %s", firstValidIndex, channelKey)
				chHistory.Messages = chHistory.Messages[firstValidIndex:]
			} else if firstValidIndex == -1 && len(chHistory.Messages) > 0 {
				chHistory.Messages = []Message{} // All messages are old
			}
			log.Printf("[DEBUG] After prune. Channel %s now has %d messages.", channelKey, len(chHistory.Messages))
			chHistory.mutex.Unlock()
		}

		// --- UPDATED PUSH NOTIFICATION LOGIC ---
		session.ForEachSession(func(s *session.UserSession) {
			s.Mutex.RLock()
			normalizedChannel := strings.ToLower(channel)
			_, inChannel := s.Channels[normalizedChannel]
			fcmToken := s.FCMToken
			username := s.Username
			s.Mutex.RUnlock()

			// DM (private message): channel is the recipient's nick
			if !strings.HasPrefix(channel, "#") {
				// Notify only the DM recipient (not sender), if logged in and has FCM token
				if strings.EqualFold(channel, username) && fcmToken != "" && username != sender {
					log.Printf("[Push Gateway] Notifying user %s of DM from %s", username, sender)
					notificationTitle := fmt.Sprintf("Direct message from %s", sender)
					notificationBody := messageContent
					data := map[string]string{
						"sender":       sender,
						"channel_name": channel,
						"type":         "dm",
					}
					go func(token, title, body string, payload map[string]string) {
						err := push.SendPushNotification(token, title, body, payload)
						if err != nil {
							log.Printf("[Push Gateway] Failed to send DM notification to %s: %v", username, err)
						}
					}(fcmToken, notificationTitle, notificationBody, data)
				}
				return
			}

			// Channel message: Notify only if username is mentioned (case-insensitive, word boundary)
			if inChannel && username != sender && fcmToken != "" {
				if mentionInMessage(username, messageContent) {
					log.Printf("[Push Gateway] Notifying user %s (mention) in %s", username, channel)
					notificationTitle := fmt.Sprintf("Mention in %s", channel)
					notificationBody := fmt.Sprintf("%s: %s", sender, messageContent)
					data := map[string]string{
						"sender":       sender,
						"channel_name": channel,
						"type":         "mention",
					}
					go func(token, title, body string, payload map[string]string) {
						err := push.SendPushNotification(token, title, body, payload)
						if err != nil {
							log.Printf("[Push Gateway] Failed to send mention notification to %s: %v", username, err)
						}
					}(fcmToken, notificationTitle, notificationBody, data)
				}
			}
		})
		// --- END UPDATED LOGIC ---
	})

	// --- TOPIC HANDLING: Add callback for TOPIC and broadcast to all sessions in channel ---
	ircConn.AddCallback("TOPIC", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[0]
			topic := e.Arguments[1]

			// Broadcast topic change to all users in the channel
			session.ForEachSession(func(s *session.UserSession) {
				s.Mutex.RLock()
				_, inChannel := s.Channels[strings.ToLower(channel)]
				s.Mutex.RUnlock()

				if inChannel {
					s.Broadcast(events.EventTypeTopicChange, map[string]interface{}{
						"channel": channel,
						"topic":   topic,
						"set_by":  e.Nick,
					})
				}
			})
		}
	})

	ircConn.AddCallback("INVITE", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[1]
			log.Printf("[Gateway] Received invite to %s, joining", channel)
			ircConn.Join(channel)
			persistChannel(channel)
		}
	})

	ircConn.AddCallback("KICK", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[0]
			kickedUser := e.Arguments[1]

			if kickedUser == config.Cfg.GatewayNick {
				log.Printf("[Gateway] Kicked from %s, removing from persisted channels", channel)
				unpersistChannel(channel)
			}
		}
	})

	go ircConn.Loop()
	return nil
}

// Exported for use by handlers
func JoinChannel(channel string) {
	if gatewayConn != nil {
		gatewayConn.Join(channel)
		persistChannel(channel)
	}
}

// Exported for use by handlers
func PartChannel(channel string) {
	if gatewayConn != nil {
		gatewayConn.Part(channel)
		unpersistChannel(channel)
	}
}

// Exported for use by handlers
func GetChannelHistory(channel string, limit int) []Message {
	channelKey := strings.ToLower(channel)
	historyMutex.RLock()
	chHistory, exists := historyMap[channelKey]
	historyMutex.RUnlock()

	if !exists {
		log.Printf("[Gateway] No history found for channel %s", channelKey)
		return nil
	}

	chHistory.mutex.RLock()
	defer chHistory.mutex.RUnlock()

	if len(chHistory.Messages) == 0 {
		log.Printf("[Gateway] Channel %s history is empty", channelKey)
		return nil
	}

	if limit <= 0 || limit >= len(chHistory.Messages) {
		log.Printf("[Gateway] Returning all %d messages for channel %s", len(chHistory.Messages), channelKey)
		return chHistory.Messages
	}

	log.Printf("[Gateway] Returning last %d messages for channel %s", limit, channelKey)
	return chHistory.Messages[len(chHistory.Messages)-limit:]
}