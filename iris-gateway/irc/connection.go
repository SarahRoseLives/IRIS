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
)

// Define a type alias for the IRC client.
type IRCClient = ircevent.Connection

// ChannelStateUpdater is an interface that defines methods for updating channel state
// within the session. This is passed from the session to the IRC layer to avoid
// direct import cycles.
type ChannelStateUpdater interface {
    AddChannelToSession(channelName string)
    RemoveChannelFromSession(channelName string)
    UpdateChannelMembers(channelName string, members []string)
    AddMessageToChannel(channelName, sender, messageContent string) // New method for message history
}

// AuthenticateWithNickServ establishes an IRC connection, authenticates,
// and sets up callbacks to update the session state.
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

    connClient.AddCallback("PRIVMSG", func(e *ircevent.Event) {
        target := e.Arguments[0] // Target can be a channel or a user
        messageContent := e.Arguments[1]
        sender := e.Nick
        log.Printf("[IRC] Message from %s in %s: %s\n", sender, target, messageContent)

        // Always normalize the channel name for internal storage and WebSocket broadcasting
        // so that keys are consistent (e.g., always "#welcome", never "#Welcome").
        normalizedTarget := strings.ToLower(target)

        // Add message to channel history ONLY if it's a channel message
        if sessionUpdater != nil && strings.HasPrefix(target, "#") {
            sessionUpdater.AddMessageToChannel(normalizedTarget, sender, messageContent)
        }

        // Always broadcast the message, sending the normalized channel name
        events.SendEvent("message", map[string]string{
            "channel_name": normalizedTarget, // Use normalizedTarget here for consistency!
            "sender":       sender,
            "text":         messageContent,
        })
    }) // Added missing closing parenthesis and brace. Also removed the duplicate events.SendEvent.

    // NAMES reply handler (RPL_NAMREPLY - 353) to get initial member list
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