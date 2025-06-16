package irc

import (
	"fmt"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/events" // IMPORANT: Import the new events package
)

// Define a type alias so that other packages can use the same type.
type IRCClient = ircevent.Connection

func AuthenticateWithNickServ(username, password string) (*IRCClient, error) {
	conn := ircevent.IRC(username, "iris-gateway")
	conn.VerboseCallbackHandler = false
	conn.Debug = false
	conn.UseTLS = false

	conn.UseSASL = true
	conn.SASLLogin = username
	conn.SASLPassword = password

	saslDone := make(chan error, 1)

	// Successful SASL
	conn.AddCallback("903", func(e *ircevent.Event) {
		fmt.Println("SASL 903: Authentication successful.")
		conn.SendRaw("CAP END")
		select {
		case saslDone <- nil:
		default:
		}
	})

	// Failures
	conn.AddCallback("904", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication failed")
	})
	conn.AddCallback("905", func(e *ircevent.Event) {
		saslDone <- fmt.Errorf("SASL authentication aborted")
	})

	// Diagnostics
	conn.AddCallback("001", func(e *ircevent.Event) {
		fmt.Println("Received 001, connection established")
	})
	conn.AddCallback("376", func(e *ircevent.Event) {
		fmt.Println("Received End of MOTD (376)")
		// Fallback in case 903 is missed
		select {
		case saslDone <- nil:
		default:
		}
	})

	// --- IRC Event Callbacks for WebSocket Broadcasting ---

	// Callback for JOIN events (when someone joins a channel)
	conn.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0] // Channel name is the first argument
		userName := e.Nick            // The user who joined
		fmt.Printf("[IRC] User %s JOINED %s\n", userName, channelName)

		events.SendEvent("channel_join", map[string]string{
			"name": channelName,
			"user": userName, // Include the user who joined
		})
	})

	// Callback for PART events (when someone leaves a channel)
	conn.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0] // Channel name is the first argument
		userName := e.Nick            // The user who parted
		fmt.Printf("[IRC] User %s PARTED %s\n", userName, channelName)

		events.SendEvent("channel_part", map[string]string{
			"name": channelName,
			"user": userName, // Include the user who parted
		})
	})

	// Callback for PRIVMSG events (chat messages)
	conn.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]    // The channel or nick where the message was sent
		messageContent := e.Arguments[1] // The actual message text
		sender := e.Nick            // The sender's nick

		fmt.Printf("[IRC] Message from %s in %s: %s\n", sender, sender, messageContent) // Corrected logging of sender

		events.SendEvent("message", map[string]string{
			"channel_name": target,
			"sender":       sender,
			"text":         messageContent,
		})
	})

	// --- End IRC Event Callbacks ---

	if err := conn.Connect(config.Cfg.IRCServer); err != nil {
		return nil, fmt.Errorf("failed to connect to IRC: %w", err)
	}

	go conn.Loop() // Start the IRC connection loop in a goroutine

	select {
	case err := <-saslDone:
		if err != nil {
			return nil, err
		}
		return conn, nil
	case <-time.After(15 * time.Second):
		return nil, fmt.Errorf("SASL authentication timed out")
	}
}
