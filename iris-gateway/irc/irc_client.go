package irc

import (
	"crypto/tls"
	"fmt"
	"log"
	"math"
	"regexp"
	"strings"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/events"
	"iris-gateway/push"
	"iris-gateway/session"
)

// IRCClientWrapper wraps ircevent.Connection and adds session/network context.
type IRCClientWrapper struct {
	*ircevent.Connection
	UserSession   *session.UserSession
	NetworkConfig *session.UserNetwork
}

// EstablishIRCConnection establishes an IRC connection for a specific UserNetwork.
// It returns an IRCClientWrapper and any error.
func EstablishIRCConnection(
	userSession *session.UserSession,
	netConfig *session.UserNetwork,
	clientIP string,
) (*IRCClientWrapper, error) {
	// --- BEGIN GATEKEEPER LOGIC ---
	netConfig.Mutex.Lock()
	if netConfig.IsConnecting || netConfig.ReconnectTimer != nil {
		netConfig.Mutex.Unlock()
		log.Printf("[IRC] Network %s: Aborting connection attempt, another one is already in progress.", netConfig.NetworkName)
		return nil, fmt.Errorf("connection attempt already in progress for network %s", netConfig.NetworkName)
	}
	netConfig.IsConnecting = true
	netConfig.Mutex.Unlock()

	defer func() {
		netConfig.Mutex.Lock()
		netConfig.IsConnecting = false
		netConfig.Mutex.Unlock()
		log.Printf("[IRC] Network %s: Connection attempt has finished.", netConfig.NetworkName)
	}()
	// --- END GATEKEEPER LOGIC ---

	ircServerAddr := fmt.Sprintf("%s:%d", netConfig.Hostname, netConfig.Port)

	// Ensure ident is not empty.
	ident := netConfig.Ident
	if strings.TrimSpace(ident) == "" {
		ident = netConfig.Nickname
		log.Printf("[IRC] Network %s: Ident is empty, defaulting to nickname '%s'", netConfig.NetworkName, ident)
	}

	ircClient := ircevent.IRC(netConfig.Nickname, ident)
	ircClient.RealName = netConfig.Realname
	ircClient.UseTLS = netConfig.UseSSL

	if ircClient.UseTLS {
		ircClient.TLSConfig = &tls.Config{
			ServerName: netConfig.Hostname,
			MinVersion: tls.VersionTLS12,
		}
		log.Printf("[IRC] Network %s: TLS enabled with SNI for host '%s'", netConfig.NetworkName, netConfig.Hostname)
	}

	ircClient.VerboseCallbackHandler = false
	ircClient.Debug = true

	ircClient.RequestCaps = []string{
		"server-time",
		"away-notify",
		"multi-prefix",
		"sasl",
		"draft/chathistory",
		"draft/event-playback",
	}

	connectionDone := make(chan error, 1)

	ircWrapper := &IRCClientWrapper{
		Connection:    ircClient,
		UserSession:   userSession,
		NetworkConfig: netConfig,
	}

	addIRCEventHandlers(ircWrapper, connectionDone)

	hasSASLModule := false
	for _, module := range netConfig.Modules {
		if strings.ToLower(module) == "sasl" {
			hasSASLModule = true
			break
		}
	}

	if hasSASLModule && netConfig.ServerPassword != "" {
		ircClient.UseSASL = true
		ircClient.SASLLogin = netConfig.Nickname
		ircClient.SASLPassword = netConfig.ServerPassword
		log.Printf("[IRC] Network %s: SASL enabled with login %s", netConfig.NetworkName, ircClient.SASLLogin)
		ircClient.AddCallback("904", func(e *ircevent.Event) {
			connectionDone <- fmt.Errorf("SASL authentication failed (904): %s", e.Message())
		})
		ircClient.AddCallback("905", func(e *ircevent.Event) {
			connectionDone <- fmt.Errorf("SASL authentication aborted (905): %s", e.Message())
		})
	} else {
		ircClient.Password = netConfig.ServerPassword
	}

	log.Printf("[IRC] User %s, Network %s: Attempting to connect to %s...", userSession.Username, netConfig.NetworkName, ircServerAddr)
	if err := ircClient.Connect(ircServerAddr); err != nil {
		return nil, fmt.Errorf("failed to connect ircevent client to %s: %w", ircServerAddr, err)
	}

	go ircClient.Loop()

	select {
	case err := <-connectionDone:
		if err != nil {
			ircClient.Quit()
			return nil, err
		}
	case <-time.After(40 * time.Second):
		ircClient.Quit()
		return nil, fmt.Errorf("authentication/connection timed out for %s on network %s", netConfig.Nickname, netConfig.NetworkName)
	}

	for _, cmd := range netConfig.PerformCommands {
		log.Printf("[IRC] Network %s: Executing perform command: %s", netConfig.NetworkName, cmd)
		ircClient.SendRaw(cmd)
		time.Sleep(100 * time.Millisecond)
	}

	for _, channel := range netConfig.InitialChannels {
		log.Printf("[IRC] Network %s: Joining initial channel: %s", netConfig.NetworkName, channel)
		ircClient.Join(channel)
		time.Sleep(150 * time.Millisecond)
	}

	return ircWrapper, nil
}

// addIRCEventHandlers sets up callbacks for a given IRCClientWrapper.
func addIRCEventHandlers(irc *IRCClientWrapper, connectionDone chan error) {
	s := irc.UserSession
	netConfig := irc.NetworkConfig

	irc.AddCallback("001", func(e *ircevent.Event) {
		log.Printf("[IRC] User %s, Network %s: Successfully connected to IRC server (001).", s.Username, netConfig.NetworkName)
		netConfig.Mutex.Lock()
		netConfig.IsConnected = true
		netConfig.ReconnectAttempts = 0
		netConfig.Mutex.Unlock()

		irc.SendRaw("CAP END")

		select {
		case connectionDone <- nil:
		default:
		}

		s.Broadcast(events.EventTypeNetworkConnect, map[string]interface{}{
			"network_id":   netConfig.ID,
			"network_name": netConfig.NetworkName,
			"status":       "connected",
			"nickname":     e.Arguments[0],
		})

		irc.SendRaw("LIST")
	})

	// --- START FIX: Robust BATCH Parsing ---
	irc.AddCallback("BATCH", func(e *ircevent.Event) {
		if len(e.Arguments) < 3 || e.Arguments[1] != "chathistory-messages" {
			return
		}

		channelName := e.Arguments[2]

		// The go-ircevent library may not parse all tags correctly for BATCH.
		// We need to parse the raw message to be sure.
		// Raw format: @tags :nick!user@host COMMAND params
		rawString := e.Raw

		// 1. Isolate the tags part (starts with '@', ends with ' ')
		if !strings.HasPrefix(rawString, "@") { return }
		tagsPartEnd := strings.Index(rawString, " :")
		if tagsPartEnd == -1 { return }
		tagsPart := rawString[1:tagsPartEnd]

		// 2. Split tags and create a map
		tagsMap := make(map[string]string)
		for _, tag := range strings.Split(tagsPart, ";") {
			parts := strings.SplitN(tag, "=", 2)
			if len(parts) == 2 {
				tagsMap[parts[0]] = parts[1]
			}
		}

		// 3. Extract the message content (everything after the final ':')
		messageContentStart := strings.LastIndex(rawString, " :")
		if messageContentStart == -1 { return }
		messageContent := rawString[messageContentStart+2:]

		// 4. Extract the sender's nick
		senderStart := strings.Index(rawString, ":") + 1
		senderEnd := strings.Index(rawString, "!")
		if senderStart == 0 || senderEnd == -1 { return }
		senderNick := rawString[senderStart:senderEnd]

		// 5. Parse the timestamp from the 'time' tag
		timestamp := time.Now() // Default to now
		if t, ok := tagsMap["time"]; ok {
			parsedTime, err := time.Parse(time.RFC3339, t)
			if err == nil {
				timestamp = parsedTime
			}
		}

		// 6. Create the message and add it to history
		messageToStore := Message{
			NetworkID: netConfig.ID,
			Channel:   channelName,
			Sender:    senderNick,
			Text:      messageContent,
			Timestamp: timestamp,
		}
		AddMessageToHistory(netConfig.ID, channelName, messageToStore)

		log.Printf("[IRC] Stored 1 historical message for %s on network %s.", channelName, netConfig.NetworkName)
	})
	// --- END FIX ---

	// --- START FIX: Smarter JOIN handler for alternate nicks ---
	irc.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		joiningUser := e.Nick

		// Check against BOTH the configured nickname AND the connection's current nickname.
		currentNick := irc.GetNick()
		if strings.EqualFold(joiningUser, netConfig.Nickname) || strings.EqualFold(joiningUser, currentNick) {
			log.Printf("[IRC] User %s, Network %s: Confirmed JOIN to channel %s.", s.Username, netConfig.NetworkName, channelName)
			netConfig.AddChannelToNetwork(channelName)
			s.Broadcast(events.EventTypeChannelJoin, map[string]interface{}{
				"network_id": netConfig.ID,
				"name":       channelName,
				"user":       joiningUser,
			})
			irc.SendRaw("NAMES " + channelName)
			irc.SendRaw("TOPIC " + channelName)
		} else {
			log.Printf("[IRC] User %s, Network %s: Another user (%s) joined %s. Refreshing NAMES.", s.Username, netConfig.NetworkName, joiningUser, channelName)
			irc.SendRaw("NAMES " + channelName)
		}
	})
	// --- END FIX ---

	irc.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		partingUser := e.Nick

		if strings.EqualFold(partingUser, netConfig.Nickname) {
			log.Printf("[IRC] User %s, Network %s: Confirmed PART from channel %s.", s.Username, netConfig.NetworkName, channelName)
			netConfig.RemoveChannelFromNetwork(channelName)
			s.Broadcast(events.EventTypeChannelPart, map[string]interface{}{
				"network_id": netConfig.ID,
				"name":       channelName,
				"user":       partingUser,
			})
		} else {
			log.Printf("[IRC] User %s, Network %s: Another user (%s) parted %s. Refreshing NAMES.", s.Username, netConfig.NetworkName, partingUser, channelName)
			irc.SendRaw("NAMES " + channelName)
		}
	})

	// QUIT
	irc.AddCallback("QUIT", func(e *ircevent.Event) {
		quittingUser := e.Nick
		log.Printf("[IRC] User %s, Network %s: User %s QUIT.", s.Username, netConfig.NetworkName, quittingUser)

		netConfig.Mutex.RLock()
		channelsToRefresh := make([]string, 0)
		for chName, chState := range netConfig.Channels {
			chState.Mutex.RLock()
			for _, member := range chState.Members {
				if strings.EqualFold(member.Nick, quittingUser) {
					channelsToRefresh = append(channelsToRefresh, chName)
					break
				}
			}
			chState.Mutex.RUnlock()
		}
		netConfig.Mutex.RUnlock()

		for _, channel := range channelsToRefresh {
			log.Printf("[IRC] User %s, Network %s: User %s was in %s. Refreshing NAMES for that channel.", s.Username, netConfig.NetworkName, quittingUser, channel)
			irc.SendRaw("NAMES " + channel)
			time.Sleep(150 * time.Millisecond)
		}
	})

	irc.AddCallback("353", func(e *ircevent.Event) {
		if len(e.Arguments) >= 4 {
			channelName := e.Arguments[len(e.Arguments)-2]
			membersString := e.Arguments[len(e.Arguments)-1]
			members := strings.Fields(membersString)
			log.Printf("[IRC] User %s, Network %s: Received NAMES chunk for channel %s. Members: %v", s.Username, netConfig.NetworkName, channelName, members)
			netConfig.AccumulateChannelMembers(channelName, members)
		}
	})

	irc.AddCallback("366", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channelName := e.Arguments[1]
			log.Printf("[IRC] User %s, Network %s: End of NAMES list for %s. Finalizing.", s.Username, netConfig.NetworkName, channelName)
			netConfig.FinalizeChannelMembers(channelName)
		}
	})

	irc.AddCallback("332", func(e *ircevent.Event) {
		if len(e.Arguments) >= 3 {
			channelName := e.Arguments[1]
			topic := e.Arguments[2]
			log.Printf("[IRC] User %s, Network %s: Received initial TOPIC (332) for %s: %s", s.Username, netConfig.NetworkName, channelName, topic)
			netConfig.SetChannelTopic(channelName, topic)
			s.Broadcast(events.EventTypeTopicChange, map[string]interface{}{
				"network_id": netConfig.ID,
				"channel":    channelName,
				"topic":      topic,
				"set_by":     "",
			})
		}
	})

	irc.AddCallback("TOPIC", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channelName := e.Arguments[0]
			topic := e.Arguments[1]
			setBy := e.Nick
			log.Printf("[IRC] User %s, Network %s: Saw TOPIC change in %s by %s", s.Username, netConfig.NetworkName, channelName, setBy)
			netConfig.SetChannelTopic(channelName, topic)
			s.Broadcast(events.EventTypeTopicChange, map[string]interface{}{
				"network_id": netConfig.ID,
				"channel":    channelName,
				"topic":      topic,
				"set_by":     setBy,
			})
		}
	})

	irc.AddCallback("AWAY", func(e *ircevent.Event) {
		awayUserNick := e.Nick
		isNowAway := len(e.Message()) > 0
		log.Printf("[IRC] User %s, Network %s: Received AWAY notification for %s. IsAway: %t", s.Username, netConfig.NetworkName, awayUserNick, isNowAway)
		netConfig.UpdateAwayStatusForNetworkMember(awayUserNick, isNowAway)
	})

	irc.AddCallback("PING", func(e *ircevent.Event) {
		irc.SendRaw("PONG " + e.Arguments[0])
	})

	// PRIVMSG (Channel messages and DMs)
	irc.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]       // Channel or our nick
		messageContent := e.Arguments[1]
		sender := e.Nick

		isPrivateMessage := !strings.HasPrefix(target, "#")
		var conversationTarget string
		if isPrivateMessage {
			conversationTarget = strings.ToLower(sender) // DM from sender appears in their "channel"
		} else {
			conversationTarget = strings.ToLower(target) // Channel message
		}

		if strings.HasPrefix(target, "#") || strings.EqualFold(target, netConfig.Nickname) {
			message := Message{
				NetworkID: netConfig.ID,
				Channel:   conversationTarget,
				Sender:    sender,
				Text:      messageContent,
				Timestamp: time.Now(),
			}
			AddMessageToHistory(netConfig.ID, conversationTarget, message)
		}

		now := time.Now()
		messageID := fmt.Sprintf("msg_%d_%s", now.UnixNano(), sender)

		s.Broadcast(events.EventTypeMessage, map[string]interface{}{
			"network_id":   netConfig.ID,
			"channel_name": conversationTarget,
			"sender":       sender,
			"text":         messageContent,
			"time":         now.UTC().Format(time.RFC3339),
			"id":           messageID,
		})

		if s.FCMToken != "" {
			if isPrivateMessage && strings.EqualFold(target, netConfig.Nickname) && !s.IsActive() {
				log.Printf("[Push] Sending DM push to %s from %s on network %s", s.Username, sender, netConfig.NetworkName)
				push.SendPushNotification(
					s.FCMToken,
					fmt.Sprintf("DM from %s on %s", sender, netConfig.NetworkName),
					messageContent,
					map[string]string{
						"network_id":   fmt.Sprintf("%d", netConfig.ID),
						"channel_name": conversationTarget,
						"sender":       sender,
						"type":         "dm",
					},
				)
			} else if !isPrivateMessage && strings.ToLower(sender) != strings.ToLower(netConfig.Nickname) && mentionInMessage(netConfig.Nickname, messageContent) && !s.IsActive() {
				log.Printf("[Push] Sending mention push to %s in %s on network %s", s.Username, target, netConfig.NetworkName)
				push.SendPushNotification(
					s.FCMToken,
					fmt.Sprintf("Mention in %s on %s", target, netConfig.NetworkName),
					fmt.Sprintf("%s: %s", sender, messageContent),
					map[string]string{
						"network_id":   fmt.Sprintf("%d", netConfig.ID),
						"channel_name": conversationTarget,
						"sender":       sender,
						"type":         "mention",
					},
				)
			}
		}
	})

	// NOTICE
	irc.AddCallback("NOTICE", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick
		if sender == "" {
			sender = e.Source
		}

		s.Broadcast(events.EventTypeNotice, map[string]interface{}{
			"network_id":   netConfig.ID,
			"channel_name": target,
			"sender":       sender,
			"text":         messageContent,
			"time":         time.Now().UTC().Format(time.RFC3339),
		})
	})

	// DISCONNECT
	irc.AddCallback("DISCONNECT", func(e *ircevent.Event) {
		log.Printf("[IRC] User %s, Network %s: Disconnected from IRC.", s.Username, netConfig.NetworkName)

		netConfig.Mutex.Lock()
		wasConnected := netConfig.IsConnected
		netConfig.IsConnected = false
		netConfig.IRC = nil
		netConfig.Mutex.Unlock()

		if wasConnected {
			s.Broadcast(events.EventTypeNetworkDisconnect, map[string]interface{}{
				"network_id":   netConfig.ID,
				"network_name": netConfig.NetworkName,
				"status":       "disconnected",
				"reason":       e.Message(),
			})
		}

		if netConfig.AutoReconnect {
			netConfig.Mutex.Lock()
			defer netConfig.Mutex.Unlock()

			if netConfig.ReconnectTimer == nil {
				netConfig.ReconnectAttempts++
				attempts := netConfig.ReconnectAttempts

				delaySec := math.Pow(2, float64(attempts))
				if delaySec > 120 {
					delaySec = 120
				}
				delay := time.Duration(delaySec) * time.Second

				log.Printf("[IRC] Scheduling reconnect for %s in %v (attempt %d)", netConfig.NetworkName, delay, attempts)

				netConfig.ReconnectTimer = time.AfterFunc(delay, func() {
					netConfig.Mutex.Lock()
					netConfig.ReconnectTimer = nil
					netConfig.Mutex.Unlock()

					log.Printf("[IRC] Attempting auto-reconnect for %s (attempt %d)", netConfig.NetworkName, attempts)
					newIRC, connErr := EstablishIRCConnection(s, netConfig, "")
					if connErr != nil {
						log.Printf("[IRC] Reconnect failed for %s: %v", netConfig.NetworkName, connErr)
					} else {
						netConfig.Mutex.Lock()
						netConfig.IRC = newIRC.Connection
						netConfig.IsConnected = true
						netConfig.Mutex.Unlock()
						log.Printf("[IRC] Reconnect successful for %s", netConfig.NetworkName)
					}
				})
			} else {
				log.Printf("[IRC] Reconnect already scheduled for %s", netConfig.NetworkName)
			}
		}
	})
}

func mentionInMessage(username, text string) bool {
	pattern := fmt.Sprintf(`(?i)\b%s\b`, regexp.QuoteMeta(username))
	matched, _ := regexp.MatchString(pattern, text)
	return matched
}