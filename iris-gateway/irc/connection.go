package irc

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/push"
	"iris-gateway/session"
)

// REMOVE duplicate Message struct! Use the one in gateway.go

// Offline message storage for DMs
var offlineMessages = struct {
	sync.RWMutex
	m map[string][]Message // Key: username, Value: messages
}{m: make(map[string][]Message)}

type IRCClient = ircevent.Connection

type ChannelStateUpdater interface {
	AddChannelToSession(channelName string)
	RemoveChannelFromSession(channelName string)
	AccumulateChannelMembers(channelName string, members []string)
	FinalizeChannelMembers(channelName string)
}

// --- REMOVED Disconnect method ---

func AuthenticateWithNickServ(username, password, clientIP string, userSession *session.UserSession) (*IRCClient, error) {
	ircServerAddr := config.Cfg.IRCServer
	conn, err := net.DialTimeout("tcp", ircServerAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("failed to dial IRC server %s: %w", ircServerAddr, err)
	}
	srcIP := net.ParseIP(clientIP)
	if srcIP == nil {
		log.Printf("Warning: Could not parse client IP '%s', defaulting to 127.0.0.1 for PROXY header.", clientIP)
		clientIP = "127.0.0.1"
		srcIP = net.ParseIP(clientIP)
	}

	var proxyHeader string
	localAddr := conn.LocalAddr().(*net.TCPAddr)
	localIP := localAddr.IP.String()
	localPort := localAddr.Port

	if srcIP.To4() != nil {
		proxyHeader = fmt.Sprintf("PROXY TCP4 %s %s 0 %d\r\n", clientIP, localIP, localPort)
	} else if srcIP.To16() != nil {
		proxyHeader = fmt.Sprintf("PROXY TCP6 %s %s 0 %d\r\n", clientIP, localIP, localPort)
	} else {
		log.Printf("Warning: Unknown IP type for client IP '%s', skipping PROXY header.", clientIP)
		conn.Close()
		return nil, fmt.Errorf("unsupported client IP type for PROXY protocol: %s", clientIP)
	}

	log.Printf("[IRC Connect] Sending PROXY header: %q", proxyHeader)
	_, err = conn.Write([]byte(proxyHeader))
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to send PROXY header to IRC server: %w", err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to create local listener for IRC proxy: %w", err)
	}
	defer ln.Close()

	localProxyAddr := ln.Addr().String()

	go func() {
		clientConnFromIRC, err := ln.Accept()
		if err != nil {
			log.Printf("[IRC Proxy] Error accepting connection from IRC client: %v", err)
			return
		}
		defer clientConnFromIRC.Close()

		done := make(chan struct{})
		go func() {
			_, err := io.Copy(conn, clientConnFromIRC)
			if err != nil && err != io.EOF {
				log.Printf("[IRC Proxy] Error copying data from IRC client to IRC server: %v", err)
			}
			done <- struct{}{}
		}()
		go func() {
			_, err := io.Copy(clientConnFromIRC, conn)
			if err != nil && err != io.EOF {
				log.Printf("[IRC Proxy] Error copying data from IRC server to IRC client: %v", err)
			}
			done <- struct{}{}
		}()

		<-done
		clientConnFromIRC.Close()
		conn.Close()
		log.Println("[IRC Proxy] Connection proxying finished.")
	}()

	connClient := ircevent.IRC(username, "iris-gateway")
	connClient.VerboseCallbackHandler = false
	connClient.Debug = false
	connClient.UseTLS = false
	// Enable IRCv3 capabilities, including away-notify
	connClient.RequestCaps = []string{"server-time", "away-notify", "multi-prefix"}
	connClient.UseSASL = true
	connClient.SASLLogin = username
	connClient.SASLPassword = password

	saslDone := make(chan error, 1)

	connClient.AddCallback("903", func(e *ircevent.Event) {
		fmt.Println("SASL 903: Authentication successful.")
		connClient.SendRaw("CAP END")
		select {
		case saslDone <- nil:
		default:
		}
	})
	connClient.AddCallback("904", func(e *ircevent.Event) { saslDone <- fmt.Errorf("SASL authentication failed") })
	connClient.AddCallback("905", func(e *ircevent.Event) { saslDone <- fmt.Errorf("SASL authentication aborted") })
	connClient.AddCallback("001", func(e *ircevent.Event) { fmt.Println("Received 001, connection established") })
	connClient.AddCallback("376", func(e *ircevent.Event) {
		fmt.Println("Received End of MOTD (376)")
		connClient.SendRaw("LIST")
		log.Printf("[IRC] Requested channel list for %s after SASL auth", username)
		select {
		case saslDone <- nil:
		default:
		}
	})

	connClient.AddCallback("322", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[1]
			userSession.AddChannelToSession(channel)
			log.Printf("[IRC] Channel from LIST detected: %s for user %s", channel, username)
		}
	})

	connClient.AddCallback("323", func(e *ircevent.Event) {
		log.Printf("[IRC] End of LIST for %s. Requesting NAMES for all detected channels.", username)
		userSession.Mutex.RLock()
		channelsToUpdate := make([]string, 0, len(userSession.Channels))
		for chName := range userSession.Channels {
			channelsToUpdate = append(channelsToUpdate, chName)
		}
		userSession.Mutex.RUnlock()

		go func() {
			for _, channel := range channelsToUpdate {
				if strings.HasPrefix(channel, "#") {
					connClient.SendRaw("NAMES " + channel)
					log.Printf("[IRC] Requested initial NAMES for %s", channel)
					time.Sleep(150 * time.Millisecond)
				}
			}
		}()
	})

	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		joiningUser := e.Nick

		if joiningUser == username {
			log.Printf("[IRC] User %s confirmed JOIN to channel %s.", username, channelName)
			userSession.AddChannelToSession(channelName)
			userSession.Broadcast("channel_join", map[string]interface{}{
				"name": channelName,
				"user": username,
			})
			connClient.SendRaw("NAMES " + channelName)
			log.Printf("[IRC] Requested NAMES for newly joined channel %s", channelName)
			// --- CHANGE: RESTORED this line to request the topic upon joining.
			connClient.SendRaw("TOPIC " + channelName)
		} else {
			log.Printf("[IRC] Another user (%s) joined %s. Refreshing NAMES.", joiningUser, channelName)
			connClient.SendRaw("NAMES " + channelName)
		}
	})

	connClient.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		partingUser := e.Nick
		log.Printf("[IRC] Received PART event. User: %s, Channel: %s", partingUser, channelName)

		if partingUser == username {
			userSession.RemoveChannelFromSession(channelName)
			userSession.Broadcast("channel_part", map[string]interface{}{
				"name": channelName,
				"user": partingUser,
			})
		} else {
			log.Printf("[IRC] Another user (%s) parted %s. Refreshing NAMES for our session.", partingUser, channelName)
			connClient.SendRaw("NAMES " + channelName)
		}
	})

	// --- START OF CHANGE ---
	// This handles RPL_TOPIC (332), which is sent ONLY to the user joining a channel.
	// This is NOT redundant and is required for the user to get the initial topic.
	connClient.AddCallback("332", func(e *ircevent.Event) {
		if len(e.Arguments) >= 3 {
			channelName := e.Arguments[1]
			topic := e.Arguments[2]

			log.Printf("[IRC] Received initial TOPIC (332) for %s: %s", channelName, topic)

			// Update this user's session state and broadcast ONLY to this user's clients.
			userSession.SetChannelTopic(channelName, topic)
			userSession.Broadcast("topic_change", map[string]interface{}{
				"channel": channelName,
				"topic":   topic,
			})
		}
	})

	// The live "TOPIC" change handler remains removed from here, as the gateway
	// bot now handles broadcasting it to all users in the channel.
	// --- END OF CHANGE ---

	if username != config.Cfg.GatewayNick {
		connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
			target := e.Arguments[0]
			messageContent := e.Arguments[1]
			sender := e.Nick

			isPrivateMessage := !strings.HasPrefix(target, "#")

			var conversationTarget string
			if isPrivateMessage {
				conversationTarget = strings.ToLower(sender)
			} else {
				conversationTarget = strings.ToLower(target)
			}

			if isPrivateMessage {
				targetUser := strings.ToLower(target)

				isOnline := false
				session.ForEachSession(func(s *session.UserSession) {
					if strings.EqualFold(s.Username, targetUser) {
						isOnline = true
					}
				})

				if !isOnline {
					offlineMessages.Lock()
					offlineMessages.m[targetUser] = append(offlineMessages.m[targetUser], Message{
						Channel:   targetUser,
						Sender:    sender,
						Text:      messageContent,
						Timestamp: time.Now(),
					})
					offlineMessages.Unlock()
					return
				}
			}

			userSession.Broadcast("message", map[string]interface{}{
				"channel_name": conversationTarget,
				"sender":       sender,
				"text":         messageContent,
				"time":         time.Now().UTC().Format(time.RFC3339),
			})

			if isPrivateMessage && strings.EqualFold(userSession.Username, target) {
				log.Printf("[Push PM] Processing inbound PM for %s from %s", target, sender)
				userSession.Mutex.RLock()
				fcmToken := userSession.FCMToken
				userSession.Mutex.RUnlock()

				if fcmToken != "" {
					log.Printf("[Push PM] Recipient %s has FCM token. Attempting to send push notification.", userSession.Username)
					go func() {
						err := push.SendPushNotification(
							fcmToken,
							fmt.Sprintf("New message from %s", sender),
							messageContent,
							map[string]string{
								"sender":       sender,
								"channel_name": sender,
								"type":         "private_message",
							},
						)
						if err != nil {
							log.Printf("[Push PM] Failed to send PM push notification to %s: %v", userSession.Username, err)
						}
					}()
				} else {
					log.Printf("[Push PM] Recipient %s does not have an FCM token. Skipping push.", userSession.Username)
				}
			}
		})
	}

	connClient.AddCallback("353", func(e *ircevent.Event) {
		if len(e.Arguments) >= 4 {
			channelName := e.Arguments[len(e.Arguments)-2]
			membersString := e.Arguments[len(e.Arguments)-1]
			members := strings.Fields(membersString)
			log.Printf("[IRC] Received NAMES chunk for channel %s. Members: %v", channelName, members)
			userSession.AccumulateChannelMembers(channelName, members)
		}
	})

	connClient.AddCallback("366", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channelName := e.Arguments[1]
			log.Printf("[IRC] End of NAMES list for %s. Finalizing.", channelName)
			userSession.FinalizeChannelMembers(channelName)
		}
	})

	connClient.AddCallback("AWAY", func(e *ircevent.Event) {
		awayUserNick := e.Nick
		isNowAway := len(e.Message()) > 0
		log.Printf("[IRC] Received AWAY notification for %s. IsAway: %t", awayUserNick, isNowAway)
		session.UpdateAwayStatusForAllSessions(awayUserNick, isNowAway)
	})

	connClient.AddCallback("QUIT", func(e *ircevent.Event) {
		quittingUser := e.Nick
		log.Printf("[IRC] User %s QUIT.", quittingUser)

		userSession.Mutex.RLock()
		channelsToRefresh := make([]string, 0)
		for chName, chState := range userSession.Channels {
			for _, member := range chState.Members {
				if strings.EqualFold(member.Nick, quittingUser) {
					channelsToRefresh = append(channelsToRefresh, chName)
					break
				}
			}
		}
		userSession.Mutex.RUnlock()

		go func() {
			for _, channel := range channelsToRefresh {
				log.Printf("[IRC] User %s was in %s. Refreshing NAMES for that channel.", quittingUser, channel)
				connClient.SendRaw("NAMES " + channel)
				time.Sleep(150 * time.Millisecond)
			}
		}()
	})

	if err := connClient.Connect(localProxyAddr); err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to connect ircevent client to local proxy: %w", err)
	}

	go connClient.Loop()

	select {
	case err := <-saslDone:
		if err != nil {
			conn.Close()
			return nil, err
		}
		return connClient, nil
	case <-time.After(15 * time.Second):
		conn.Close()
		return nil, fmt.Errorf("SASL authentication timed out")
	}
}

// -- Exported helper for offline DM delivery --
func GetAndClearOfflineMessages(username string) []Message {
	user := strings.ToLower(username)
	offlineMessages.Lock()
	msgs := offlineMessages.m[user]
	if len(msgs) > 0 {
		delete(offlineMessages.m, user)
	}
	offlineMessages.Unlock()
	return msgs
}