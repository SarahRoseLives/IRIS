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

// ChannelStateUpdater interface remains, as UserSession implements it.
type ChannelStateUpdater interface {
	AddChannelToSession(channelName string)
	RemoveChannelFromSession(channelName string)
	AddMessageToChannel(channelName, sender, messageContent string)
	AccumulateChannelMembers(channelName string, members []string)
	FinalizeChannelMembers(channelName string)
}

// MODIFIED: The function now accepts the full userSession, which satisfies the ChannelStateUpdater interface.
func AuthenticateWithNickServ(username, password, clientIP string, userSession *session.UserSession) (*IRCClient, error) {
	ircServerAddr := config.Cfg.IRCServer
	conn, err := net.DialTimeout("tcp", ircServerAddr, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("failed to dial IRC server %s: %w", ircServerAddr, err)
	}
	// ... (the PROXY header logic remains unchanged)
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
		select {
		case saslDone <- nil:
		default:
		}
	})

	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		log.Printf("[IRC] User %s JOINED %s\n", userName, channelName)
		userSession.AddChannelToSession(channelName)
		userSession.Broadcast("channel_join", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		log.Printf("[IRC] User %s PARTED %s\n", userName, channelName)
		userSession.RemoveChannelFromSession(channelName)
		userSession.Broadcast("channel_part", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick
		log.Printf("[IRC] Message from %s in %s: %s\n", sender, target, messageContent)

		// --- IMAGE LINK PATCH START ---
		// If the message contains an image URL from our server, convert it to a full link
		if strings.Contains(messageContent, "/images/") {
			parts := strings.Split(messageContent, "/images/")
			if len(parts) > 1 {
				imageName := parts[1]
				// TODO: Set your real domain here; for now, just use the pattern
				messageContent = fmt.Sprintf("[image] https://yourdomain.com/images/%s", imageName)
			}
		}
		// --- IMAGE LINK PATCH END ---

		// Note: For a PM, the 'target' is the recipient's nick. For a channel, it's the channel name.
		// The client will need to differentiate.
		normalizedTarget := strings.ToLower(target)
		isChannelMessage := strings.HasPrefix(target, "#")

		if isChannelMessage {
			// Store message in the channel's history
			userSession.AddMessageToChannel(normalizedTarget, sender, messageContent)
		} else {
			// For PMs, we might want to store them in a special "channel" state as well, e.g., using the sender's name as the key
			// This allows PM history to be persisted just like channel history.
			// Let's assume the "channel" for a PM is the sender's name.
			pmChannelKey := strings.ToLower(sender)
			userSession.AddChannelToSession(pmChannelKey) // Ensures a state object exists for this PM
			userSession.AddMessageToChannel(pmChannelKey, sender, messageContent)
		}

		// Broadcast the message via WebSocket to the user's active client(s).
		// This now handles both channel messages and private messages for ONLINE users.
		userSession.Broadcast("message", map[string]string{
			"channel_name": normalizedTarget, // Client uses this to know where to put the message
			"sender":       sender,
			"text":         messageContent,
		})

		// --- PUSH NOTIFICATION LOGIC (For OFFLINE users) ---
		if isChannelMessage {
			// Logic for sending push notifications for channel mentions
			session.ForEachSession(func(s *session.UserSession) {
				if strings.Contains(messageContent, s.Username) && !s.IsActive() && s.FCMToken != "" && s.Username != sender {
					log.Printf("[Push] User %s was mentioned in %s while offline, sending push notification.", s.Username, target)
					notificationTitle := fmt.Sprintf("New mention in %s", target)
					notificationBody := fmt.Sprintf("%s: %s", sender, messageContent)
					err := push.SendPushNotification(
						s.FCMToken,
						notificationTitle,
						notificationBody,
						map[string]string{
							"sender":       sender,
							"channel_name": target,
							"type":         "channel_mention",
						},
					)
					if err != nil {
						log.Printf("[Push] Failed to send mention notification to %s: %v", s.Username, err)
					}
				}
			})
		} else {
			// RESTORED: Logic for sending push notifications for private messages
			recipientUsername := target
			if recipientUsername != "" {
				token, found := session.FindSessionTokenByUsername(recipientUsername)
				if !found {
					log.Printf("[Push] Cannot send PM notification, user session not found for %s", recipientUsername)
					return
				}

				recipientSession, _ := session.GetSession(token)
				if recipientSession != nil && !recipientSession.IsActive() && recipientSession.FCMToken != "" {
					log.Printf("[Push] User %s is offline, sending push notification for PM.", recipientUsername)
					err := push.SendPushNotification(
						recipientSession.FCMToken,
						fmt.Sprintf("New message from %s", sender), // Title
						messageContent,                             // Body
						map[string]string{
							"sender": sender,
							"type":   "private_message",
						},
					)
					if err != nil {
						log.Printf("[Push] Failed to send PM push notification to %s: %v", recipientUsername, err)
					}
				} else if recipientSession != nil && recipientSession.IsActive() {
					log.Printf("[Push] User %s is online, skipping PM push notification.", recipientUsername)
				}
			}
		}
	})

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