package irc

import (
	"fmt"
	"io" // <--- NEW: Added for io.Copy
	"log"
	"net"
	"time"

	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/events"
)

// Define a type alias so that other packages can use the same type.
type IRCClient = ircevent.Connection

// AuthenticateWithNickServ now accepts clientIP
func AuthenticateWithNickServ(username, password, clientIP string) (*IRCClient, error) {
	// 1. Establish the raw TCP connection to the real IRC server.
	ircServerAddr := config.Cfg.IRCServer
	conn, err := net.DialTimeout("tcp", ircServerAddr, 10*time.Second) // Adjust timeout as needed
	if err != nil {
		return nil, fmt.Errorf("failed to dial IRC server %s: %w", ircServerAddr, err)
	}

	// Determine if the client IP is IPv4 or IPv6 for the PROXY header.
	srcIP := net.ParseIP(clientIP)
	if srcIP == nil {
		log.Printf("Warning: Could not parse client IP '%s', defaulting to 127.0.0.1 for PROXY header.", clientIP)
		clientIP = "127.0.0.1" // Fallback if clientIP is invalid
		srcIP = net.ParseIP(clientIP)
	}

	var proxyHeader string
	// Get the local address (gateway's side of the connection to IRC)
	localAddr := conn.LocalAddr().(*net.TCPAddr)
	localIP := localAddr.IP.String()
	localPort := localAddr.Port

	// Construct PROXY protocol v1 header
	if srcIP.To4() != nil {
		// PROXY TCP4 <client IP> <gateway IP> <client port (0)> <gateway port>\r\n
		// We're using 0 for client port as we don't have it from the HTTP/WebSocket connection
		proxyHeader = fmt.Sprintf("PROXY TCP4 %s %s 0 %d\r\n",
			clientIP, localIP, localPort)
	} else if srcIP.To16() != nil { // Assuming IPv6 if not IPv4
		// PROXY TCP6 <client IP> <gateway IP> <client port (0)> <gateway port>\r\n
		proxyHeader = fmt.Sprintf("PROXY TCP6 %s %s 0 %d\r\n",
			clientIP, localIP, localPort)
	} else {
		// Fallback for unknown IP type or if it's not a valid IP
		// In a real scenario, you might want to return an error or default to no proxy header.
		// For now, we'll log and continue without a PROXY header if IP is ambiguous.
		log.Printf("Warning: Unknown IP type for client IP '%s', skipping PROXY header.", clientIP)
		// Close the directly dialed connection as we can't send a valid PROXY header
		conn.Close()
		return nil, fmt.Errorf("unsupported client IP type for PROXY protocol: %s", clientIP)
	}

	log.Printf("[IRC Connect] Sending PROXY header: %q", proxyHeader)
	_, err = conn.Write([]byte(proxyHeader))
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("failed to send PROXY header to IRC server: %w", err)
	}

	// 2. Create a listener on an ephemeral port for the go-ircevent client to connect to.
	ln, err := net.Listen("tcp", "127.0.0.1:0") // Listen on localhost, ephemeral port
	if err != nil {
		conn.Close() // Close the directly dialed connection from earlier
		return nil, fmt.Errorf("failed to create local listener for IRC proxy: %w", err)
	}
	defer ln.Close() // Ensure listener is closed when function exits

	localProxyAddr := ln.Addr().String()

	// This goroutine will handle the proxying for the single client connection.
	go func() {
		clientConnFromIRC, err := ln.Accept()
		if err != nil {
			log.Printf("[IRC Proxy] Error accepting connection from IRC client: %v", err)
			// It's important to close 'conn' if the accept fails, as it's still open.
			// This might be tricky with defer, ensure 'conn' is closed in main path on error.
			// For now, relying on the main function's error path to clean up 'conn'.
			return
		}
		defer clientConnFromIRC.Close()

		// Proxy data between clientConnFromIRC (from go-ircevent) and 'conn' (to real IRC server).
		done := make(chan struct{})
		go func() {
			_, err := io.Copy(conn, clientConnFromIRC) // Read from go-ircevent, write to IRC server
			if err != nil && err != io.EOF {
				log.Printf("[IRC Proxy] Error copying data from IRC client to IRC server: %v", err)
			}
			done <- struct{}{}
		}()
		go func() {
			_, err := io.Copy(clientConnFromIRC, conn) // Read from IRC server, write to go-ircevent
			if err != nil && err != io.EOF {
				log.Printf("[IRC Proxy] Error copying data from IRC server to IRC client: %v", err)
			}
			done <- struct{}{}
		}()

		// Wait for one side of the copy to finish.
		<-done
		// Signal the other goroutine to stop if it hasn't already.
		// This is a simple shutdown, more robust solutions might use context.
		clientConnFromIRC.Close() // Force close to unblock io.Copy
		conn.Close() // Force close to unblock io.Copy
		log.Println("[IRC Proxy] Connection proxying finished.")
	}()

	// 3. Initialize the ircevent.Connection object and tell it to connect to our local listener.
	connClient := ircevent.IRC(username, "iris-gateway")
	connClient.VerboseCallbackHandler = false
	connClient.Debug = false
	connClient.UseTLS = false // Your proxy handles the direct connection. If the IRC server uses TLS, this gets more complicated.

	connClient.UseSASL = true
	connClient.SASLLogin = username
	connClient.SASLPassword = password

	saslDone := make(chan error, 1)

	// Register SASL callbacks
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

	// Add other IRC event callbacks (JOIN, PART, PRIVMSG)
	connClient.AddCallback("JOIN", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		fmt.Printf("[IRC] User %s JOINED %s\n", userName, channelName)
		events.SendEvent("channel_join", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PART", func(e *ircevent.Event) {
		channelName := e.Arguments[0]
		userName := e.Nick
		fmt.Printf("[IRC] User %s PARTED %s\n", userName, channelName)
		events.SendEvent("channel_part", map[string]string{
			"name": channelName,
			"user": userName,
		})
	})

	connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
		target := e.Arguments[0]
		messageContent := e.Arguments[1]
		sender := e.Nick
		fmt.Printf("[IRC] Message from %s in %s: %s\n", sender, target, messageContent)
		events.SendEvent("message", map[string]string{
			"channel_name": target,
			"sender":       sender,
			"text":         messageContent,
		})
	})

	// Connect `go-ircevent` client to our local proxy listener.
	if err := connClient.Connect(localProxyAddr); err != nil {
		// Ensure the directly dialed 'conn' is closed if the client connection fails.
		// This should technically be handled by the deferred Close in the proxy goroutine,
		// but explicit closure here ensures no dangling connection.
		conn.Close()
		return nil, fmt.Errorf("failed to connect ircevent client to local proxy: %w", err)
	}

	go connClient.Loop() // Start the IRC connection loop in a goroutine

	select {
	case err := <-saslDone:
		if err != nil {
			conn.Close() // Ensure the real IRC connection is closed on SASL failure
			return nil, err
		}
		return connClient, nil
	case <-time.After(15 * time.Second):
		conn.Close() // Ensure the real IRC connection is closed on timeout
		return nil, fmt.Errorf("SASL authentication timed out")
	}
}