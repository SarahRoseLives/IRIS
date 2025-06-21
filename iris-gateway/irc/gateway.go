package irc

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
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
	gatewayConn     *ircevent.Connection
	historyMap      = make(map[string]*ChannelHistory)
	historyMutex    sync.RWMutex
	historyDuration = 7 * 24 * time.Hour // Default 7 days
)

// Call this once at startup (from main.go)
func InitGatewayBot() error {
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

	// Set up callbacks
	ircConn.AddCallback("001", func(e *ircevent.Event) {
		log.Println("[Gateway] Connected to IRC server")
	})

	ircConn.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		channel := e.Arguments[0]
		sender := e.Nick
		messageContent := e.Arguments[1]

		if !strings.HasPrefix(channel, "#") {
			return // Gateway bot only handles channel messages for history and notifications
		}

		log.Printf("[Gateway] Logging message in %s from %s: %s", channel, sender, messageContent)

		message := Message{
			Channel:   channel,
			Sender:    sender,
			Text:      messageContent,
			Timestamp: time.Now(),
		}

		channelKey := strings.ToLower(channel) // normalize channel name for map key

		historyMutex.Lock()
		chHistory, exists := historyMap[channelKey]
		if !exists {
			chHistory = &ChannelHistory{
				Messages: make([]Message, 0),
			}
			historyMap[channelKey] = chHistory
			log.Printf("[Gateway] Created new history slice for channel: %s", channelKey)
		}
		historyMutex.Unlock()

		chHistory.mutex.Lock()
		chHistory.Messages = append(chHistory.Messages, message)
		log.Printf("[Gateway] Appended message to channel %s, total now: %d", channelKey, len(chHistory.Messages))

		// Clean up old messages
		cutoff := time.Now().Add(-historyDuration)
		var firstValidIndex = -1
		for i, msg := range chHistory.Messages {
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
		chHistory.mutex.Unlock()

		// --- REVISED PUSH NOTIFICATION LOGIC ---
		normalizedChannel := strings.ToLower(channel)
		session.ForEachSession(func(s *session.UserSession) {
			s.Mutex.RLock()
			_, inChannel := s.Channels[normalizedChannel]
			fcmToken := s.FCMToken
			username := s.Username
			s.Mutex.RUnlock()

			// Conditions for sending a notification:
			// 1. User is in the channel.
			// 2. User is not the one who sent the message.
			// 3. User has registered an FCM token.
			// The !isActive check is REMOVED to ensure delivery.
			if inChannel && username != sender && fcmToken != "" {
				log.Printf("[Push Gateway] Conditions met for user %s in channel %s. Attempting to send push notification.", username, channel)

				notificationTitle := fmt.Sprintf("New message in %s", channel)
				notificationBody := fmt.Sprintf("%s: %s", sender, messageContent)
				data := map[string]string{
					"sender":       sender,
					"channel_name": channel,
					"type":         "channel_message",
				}

				// Use a goroutine to avoid blocking the message loop
				go func(token, title, body string, payload map[string]string) {
					err := push.SendPushNotification(token, title, body, payload)
					if err != nil {
						log.Printf("[Push Gateway] Failed to send notification to %s: %v", username, err)
					}
				}(fcmToken, notificationTitle, notificationBody, data)
			}
		})
		// --- END REVISED LOGIC ---
	})

	ircConn.AddCallback("INVITE", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[1]
			log.Printf("[Gateway] Received invite to %s, joining", channel)
			ircConn.Join(channel)
		}
	})

	go ircConn.Loop()
	return nil
}

// Exported for use by handlers
func JoinChannel(channel string) {
	if gatewayConn != nil {
		gatewayConn.Join(channel)
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