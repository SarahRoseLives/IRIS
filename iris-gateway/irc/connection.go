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
	"iris-gateway/events"
	"iris-gateway/push"
	"iris-gateway/session"
)

type IRCClient = ircevent.Connection

// MODIFIED: ChannelStateUpdater interface to handle member list accumulation.
type ChannelStateUpdater interface {
	AddChannelToSession(channelName string)
	RemoveChannelFromSession(channelName string)
	AddMessageToChannel(channelName, sender, messageContent string)
	AccumulateChannelMembers(channelName string, members []string) // NEW
	FinalizeChannelMembers(channelName string)                     // NEW
}

func AuthenticateWithNickServ(username, password, clientIP string, sessionUpdater ChannelStateUpdater) (*IRCClient, error) {
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

	connClient.AddCallback("904", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication failed")
	})
	connClient.AddCallback("905", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication aborted")
	})

	connClient.AddCallback("001", func(e *ircevent.Event) {
		fmt.Println("Received 001, connection established")
	})
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

		if sessionUpdater != nil {
			sessionUpdater.AddChannelToSession(channelName)
		}
		events.SendEvent("channel_join", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		log.Printf("[IRC] User %s PARTED %s\n", userName, channelName)

		if sessionUpdater != nil {
			sessionUpdater.RemoveChannelFromSession(channelName)
		}
		events.SendEvent("channel_part", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick
		log.Printf("[IRC] Message from %s in %s: %s\n", sender, target, messageContent)

		normalizedTarget := strings.ToLower(target)
		isChannelMessage := strings.HasPrefix(target, "#")

		// First, add the message to the session history if it's a channel message
		if sessionUpdater != nil && isChannelMessage {
			sessionUpdater.AddMessageToChannel(normalizedTarget, sender, messageContent)
		}

		// Second, broadcast the message via WebSocket so active clients see it immediately
		events.SendEvent("message", map[string]string{
			"channel_name": normalizedTarget,
			"sender":       sender,
			"text":         messageContent,
		})

		// --- START OF PUSH NOTIFICATION LOGIC ---

		if isChannelMessage {
			// LOGIC FOR CHANNEL MENTIONS
			// Iterate over all active sessions to see if any user was mentioned
			session.ForEachSession(func(s *session.UserSession) {
				// Check if:
				// 1. The message content contains the user's name.
				// 2. The user is currently offline (no active WebSocket).
				// 3. The user has a valid FCM token registered.
				// 4. The sender is not the user themselves (don't get notifications for your own messages).
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
							"type":         "channel_mention", // Custom type for client-side handling
						},
					)
					if err != nil {
						log.Printf("[Push] Failed to send mention notification to %s: %v", s.Username, err)
					}
				}
			})
		} else {
			// LOGIC FOR PRIVATE MESSAGES (QUERIES)
			recipientUsername := target
			if recipientUsername != "" {
				token, found := session.FindSessionTokenByUsername(recipientUsername)
				if !found {
					log.Printf("[Push] Cannot send PM notification, user session not found for %s", recipientUsername)
					return
				}

				userSession, _ := session.GetSession(token)
				// Check if:
				// 1. The user session exists.
				// 2. The user is offline.
				// 3. The user has a valid FCM token.
				if userSession != nil && !userSession.IsActive() && userSession.FCMToken != "" {
					log.Printf("[Push] User %s is offline, sending push notification for PM.", recipientUsername)
					err := push.SendPushNotification(
						userSession.FCMToken,
						fmt.Sprintf("New message from %s", sender), // Title
						messageContent,                           // Body
						map[string]string{
							"sender": sender,
							"type":   "private_message", // Custom type for client-side handling
						},
					)
					if err != nil {
						log.Printf("[Push] Failed to send PM push notification to %s: %v", recipientUsername, err)
					}
				} else if userSession != nil && userSession.IsActive() {
					log.Printf("[Push] User %s is online, skipping PM push notification.", recipientUsername)
				}
			}
		}
		// --- END OF PUSH NOTIFICATION LOGIC ---
	})

	// MODIFIED: 353 (RPL_NAMREPLY) callback to accumulate raw member names.
	connClient.AddCallback("353", func(e *ircevent.Event) {
		if len(e.Arguments) >= 4 {
			channelName := e.Arguments[len(e.Arguments)-2]
			membersString := e.Arguments[len(e.Arguments)-1]
			members := strings.Fields(membersString) // Raw members with prefixes

			log.Printf("[IRC] Received NAMES chunk for channel %s. Members: %v", channelName, members)
			if sessionUpdater != nil {
				sessionUpdater.AccumulateChannelMembers(channelName, members)
			}
		}
	})

	// MODIFIED: 366 (RPL_ENDOFNAMES) callback to finalize the member list.
	connClient.AddCallback("366", func(e *ircevent.Event) {
		if len(e.Arguments) >= 2 {
			channelName := e.Arguments[1]
			log.Printf("[IRC] End of NAMES list for %s. Finalizing.", channelName)
			if sessionUpdater != nil {
				sessionUpdater.FinalizeChannelMembers(channelName)
			}
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