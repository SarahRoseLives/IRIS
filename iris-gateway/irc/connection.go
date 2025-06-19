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
	"iris-gateway/push" // <-- Import the push package
	"iris-gateway/session" // <-- Import session to find user by name
)

// ... (IRCClient and ChannelStateUpdater remain the same) ...
type IRCClient = ircevent.Connection

type ChannelStateUpdater interface {
	AddChannelToSession(channelName string)
	RemoveChannelFromSession(channelName string)
	UpdateChannelMembers(channelName string, members []string)
	AddMessageToChannel(channelName, sender, messageContent string)
}

// ... (AuthenticateWithNickServ function signature remains the same) ...
func AuthenticateWithNickServ(username, password, clientIP string, sessionUpdater ChannelStateUpdater) (*IRCClient, error) {
    // ... (no changes to the connection logic) ...
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
		}() // Added missing closing parenthesis and brace
		go func() {
			_, err := io.Copy(clientConnFromIRC, conn)
			if err != nil && err != io.EOF {
				log.Printf("[IRC Proxy] Error copying data from IRC server to IRC client: %v", err)
			}
			done <- struct{}{}
		}() // Added missing closing parenthesis and brace

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
	}) // Added missing closing parenthesis and brace

	connClient.AddCallback("904", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication failed")
	}) // Added missing closing parenthesis and brace
	connClient.AddCallback("905", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication aborted")
	}) // Added missing closing parenthesis and brace

	connClient.AddCallback("001", func(e *ircevent.Event) {
		fmt.Println("Received 001, connection established")
	}) // Added missing closing parenthesis and brace
	connClient.AddCallback("376", func(e *ircevent.Event) {
		fmt.Println("Received End of MOTD (376)")
		select {
		case saslDone <- nil:
		default:
		}
	}) // Added missing closing parenthesis and brace

	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		log.Printf("[IRC] User %s JOINED %s\n", userName, channelName)

		if sessionUpdater != nil {
			sessionUpdater.AddChannelToSession(channelName) // This calls a method that normalizes
		}
		events.SendEvent("channel_join", map[string]string{
			"name": channelName,
			"user": userName,
		}) // Added missing closing brace
	}) // Added missing closing parenthesis

	connClient.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		log.Printf("[IRC] User %s PARTED %s\n", userName, channelName)

		if sessionUpdater != nil {
			sessionUpdater.RemoveChannelFromSession(channelName) // This calls a method that normalizes
		}
		events.SendEvent("channel_part", map[string]string{
			"name": channelName,
			"user": userName,
		}) // Added missing closing brace
	}) // Added missing closing parenthesis

	// =========================================================================
	// MODIFIED PRIVMSG CALLBACK
	// =========================================================================
	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick
		log.Printf("[IRC] Message from %s in %s: %s\n", sender, target, messageContent)

		normalizedTarget := strings.ToLower(target)

		// This handles private messages as well as channel messages
		isChannelMessage := strings.HasPrefix(target, "#")
		var recipientUsername string

		if isChannelMessage {
			// For channel messages, we don't send push notifications directly
			// to avoid spamming. This could be changed if desired.
			recipientUsername = "" // Or loop through all users in the channel
		} else {
			// This is a private message, target is the recipient's username
			recipientUsername = target
		}

		if sessionUpdater != nil && isChannelMessage {
			sessionUpdater.AddMessageToChannel(normalizedTarget, sender, messageContent)
		}

		events.SendEvent("message", map[string]string{
			"channel_name": normalizedTarget,
			"sender":       sender,
			"text":         messageContent,
		})

		// If it's a PM, check if the recipient is online. If not, send a push notification.
		if !isChannelMessage && recipientUsername != "" {
			token, found := session.FindSessionTokenByUsername(recipientUsername)
			if !found {
				log.Printf("[Push] Cannot send notification, user session not found for %s", recipientUsername)
				return
			}

			userSession, _ := session.GetSession(token)
			if userSession != nil && !userSession.IsActive() && userSession.FCMToken != "" {
				log.Printf("[Push] User %s is offline, sending push notification.", recipientUsername)
				// Send a push notification
				err := push.SendPushNotification(
					userSession.FCMToken,
					fmt.Sprintf("New message from %s", sender),
					messageContent,
					map[string]string{
						"sender": sender,
						"type": "private_message",
					},
				)
				if err != nil {
					log.Printf("[Push] Failed to send push notification to %s: %v", recipientUsername, err)
				}
			} else {
				if userSession != nil && userSession.IsActive() {
					log.Printf("[Push] User %s is online, skipping push notification.", recipientUsername)
				}
			}
		}
	})
	// =========================================================================
	// END OF MODIFIED PRIVMSG CALLBACK
	// =========================================================================

	connClient.AddCallback("353", func(e *ircevent.Event) {
		if len(e.Arguments) >= 3 {
			channelName := e.Arguments[len(e.Arguments)-2]
			membersString := e.Arguments[len(e.Arguments)-1]
			members := strings.Fields(strings.TrimPrefix(membersString, ":"))
			cleanedMembers := make([]string, 0, len(members))
			for _, member := range members {
				cleanedMembers = append(cleanedMembers, strings.TrimLeftFunc(member, func(r rune) bool {
					return strings.ContainsRune("@+%", r)
				})) // Added missing closing parenthesis
			}

			log.Printf("[IRC] Received NAMES for channel %s. Members: %v", channelName, cleanedMembers)
			if sessionUpdater != nil {
				sessionUpdater.UpdateChannelMembers(channelName, cleanedMembers) // This calls a method that normalizes
			}
		}
	}) // Added missing closing parenthesis and brace

	// End of NAMES list (RPL_ENDOFNAMES - 366)
	connClient.AddCallback("366", func(e *ircevent.Event) {
		channelName := e.Arguments[1]
		log.Printf("[IRC] End of NAMES list for %s", channelName)
	}) // Added missing closing parenthesis and brace

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