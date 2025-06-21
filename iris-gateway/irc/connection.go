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
			userSession.AddChannelToSession(channel)
			log.Printf("[IRC] Auto-joined channel detected: %s", channel)
		}
	})

	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		if e.Nick == username {
			channelName := e.Arguments[0]
			log.Printf("[IRC] Auto-joined to channel %s via SASL", channelName)
			userSession.AddChannelToSession(channelName)
			userSession.Broadcast("channel_join", map[string]string{
				"name": channelName,
				"user": username,
			})
			JoinChannel(channelName)
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

	// This callback handles messages sent directly to the user (PMs)
	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick

		// Always broadcast the message over WebSocket for active clients
		userSession.Broadcast("message", map[string]string{
			"channel_name": strings.ToLower(target),
			"sender":       sender,
			"text":         messageContent,
		})

		// If it's a channel message, the central gateway bot handles it. Do nothing here.
		if strings.HasPrefix(target, "#") {
			return
		}

		// --- REVISED PM NOTIFICATION LOGIC ---
		// This event fires on the recipient's connection.
		// The `target` is the recipient's own username.
		// The `userSession` in this scope is the recipient's session.

		// 1. Check if the event is for a message this user received (not one they sent).
		if !strings.EqualFold(userSession.Username, target) {
			return
		}

		// 2. Check if the user is messaging themselves.
		if strings.EqualFold(userSession.Username, sender) {
			return
		}

		log.Printf("[Push PM] Processing inbound PM for %s from %s", target, sender)

		// 3. Get the FCM token from the current user's session.
		userSession.Mutex.RLock()
		fcmToken := userSession.FCMToken
		userSession.Mutex.RUnlock()

		// 4. If a token exists, send the notification.
		if fcmToken != "" {
			log.Printf("[Push PM] Recipient %s has FCM token. Attempting to send push notification.", userSession.Username)
			go func() {
				err := push.SendPushNotification(
					fcmToken,
					fmt.Sprintf("New message from %s", sender),
					messageContent,
					map[string]string{
						"sender": sender,
						"type":   "private_message",
					},
				)
				if err != nil {
					log.Printf("[Push PM] Failed to send PM push notification to %s: %v", userSession.Username, err)
				}
			}()
		} else {
			log.Printf("[Push PM] Recipient %s does not have an FCM token. Skipping push.", userSession.Username)
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