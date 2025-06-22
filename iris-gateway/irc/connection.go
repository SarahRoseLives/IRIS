// irc/connection.go

package irc

import (
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/push"
	"iris-gateway/session"
)

type IRCClient = ircevent.Connection

type ChannelStateUpdater interface {
	AddChannelToSession(channelName string)
	RemoveChannelFromSession(channelName string)
	AccumulateChannelMembers(channelName string, members []string)
	FinalizeChannelMembers(channelName string)
}

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
		// Request the list of channels the user is in
		connClient.SendRaw("LIST")
		log.Printf("[IRC] Requested channel list for %s after SASL auth", username)
		select {
		case saslDone <- nil:
		default:
		}
	})

	connClient.AddCallback("322", func(e *ircevent.Event) { // LIST response
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[1]
			// Add channel to session but don't request members yet. Wait for LIST to complete.
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
					time.Sleep(150 * time.Millisecond) // Small delay to avoid flooding the server
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

	// FIX: This entire callback is now wrapped in an IF statement.
	// It will only be added to user connections, not the gateway bot's connection.
	// This prevents it from interfering with the gateway's own PRIVMSG handler
	// which is responsible for logging history and sending mention notifications.
	if username != config.Cfg.GatewayNick {
		connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
			target := e.Arguments[0]
			messageContent := e.Arguments[1]
			sender := e.Nick

			isPrivateMessage := !strings.HasPrefix(target, "#")

			var conversationTarget string
			if isPrivateMessage {
				// For a PM, the target from IRC is our own nick. The conversation is with the sender.
				conversationTarget = strings.ToLower(sender)
			} else {
				// For a channel message, the target is the channel name.
				conversationTarget = strings.ToLower(target)
			}

			// Always broadcast the message over WebSocket for active clients
			userSession.Broadcast("message", map[string]interface{}{
				"channel_name": conversationTarget,
				"sender":       sender,
				"text":         messageContent,
				"time":         time.Now().UTC().Format(time.RFC3339),
			})

			// --- Push Notification Logic for DMs for this specific user ---
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
								"channel_name": sender, // For PMs, the "channel" is the other user
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