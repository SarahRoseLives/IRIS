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
		// After MOTD, request channel list to sync state
		connClient.SendRaw("LIST")
		log.Printf("[IRC] Requested channel list for %s after SASL auth", username)
		select {
		case saslDone <- nil:
		default:
		}
	})

	// Handle the LIST response to sync channels
	connClient.AddCallback("322", func(e *ircevent.Event) { // LIST response
		if len(e.Arguments) >= 2 {
			channel := e.Arguments[1]
			userSession.AddChannelToSession(channel)
			log.Printf("[IRC] Auto-joined channel detected: %s", channel)
		}
	})

	// --- JOIN CALLBACK: Only process our own JOINs (after SASL/auth) ---
	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		// Only process our own JOINs (the user this client is connected as)
		if e.Nick == username {
			channelName := e.Arguments[0]
			log.Printf("[IRC] Auto-joined to channel %s via SASL", channelName)
			userSession.AddChannelToSession(channelName)
			userSession.Broadcast("channel_join", map[string]string{
				"name": channelName,
				"user": username,
			})
		}
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

	// PRIVMSG callback for regular and image messages
	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
    target := e.Arguments[0]
    messageContent := e.Arguments[1]
    sender := e.Nick

    // Broadcast the message via WebSocket to the user's active client(s).
    userSession.Broadcast("message", map[string]string{
        "channel_name": strings.ToLower(target),
        "sender":       sender,
        "text":         messageContent, // Raw unmodified message
    })

    // --- PUSH NOTIFICATION LOGIC (For OFFLINE users) ---
    isChannelMessage := strings.HasPrefix(target, "#")
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
        // Logic for sending push notifications for private messages
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
                    fmt.Sprintf("New message from %s", sender),
                    messageContent,
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

	// PRIVMSG callback for IRC history responses
	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		// Check if this is a history response (assuming server formats them with a prefix)
		if strings.HasPrefix(e.Arguments[1], "[History]") {
			parts := strings.SplitN(e.Arguments[1], " ", 3)
			if len(parts) >= 3 {
				channel := e.Arguments[0]
				timestamp := parts[1]
				message := parts[2]

				// Broadcast as historical message
				userSession.Broadcast("history_message", map[string]string{
					"channel_name": strings.ToLower(channel),
					"sender":       e.Nick,
					"text":         message,
					"timestamp":    timestamp,
				})
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