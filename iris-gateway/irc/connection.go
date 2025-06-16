package irc

import (
    "encoding/base64"
    "fmt"
    "strings"
    "time"

    "iris-gateway/config"
    ircevent "github.com/thoj/go-ircevent"
)

// Define a type alias so that other packages can use the same type.
type IRCClient = ircevent.Connection

func AuthenticateWithNickServ(username, password string) (*IRCClient, error) {
    // Create the IRC connection.
    conn := ircevent.IRC(username, "iris-gateway")
    // Disable extra logging.
    conn.VerboseCallbackHandler = false
    conn.Debug = false
    conn.UseTLS = false
    // Disable automatic SASL so we can perform our one-shot auth.
    conn.UseSASL = false

    // Flag to prevent sending AUTHENTICATE more than once.
    authSent := false
    // Channel to signal whether SASL authentication is done.
    saslDone := make(chan error, 1)

    // Callback for initial welcome—even though we won’t use it as our signal.
    conn.AddCallback("001", func(e *ircevent.Event) {
        fmt.Println("Received 001, connection established")
    })

    // Use the End-of-MOTD ("376") as our success signal.
    conn.AddCallback("376", func(e *ircevent.Event) {
        fmt.Println("Received End of MOTD (376), marking successful auth")
        // Non-blocking send in case another callback already fired.
        select {
        case saslDone <- nil:
        default:
        }
    })

    conn.AddCallback("CAP", func(e *ircevent.Event) {
        if len(e.Arguments) >= 3 {
            switch e.Arguments[1] {
            case "LS":
                if strings.Contains(e.Arguments[2], "sasl") {
                    conn.SendRaw("CAP REQ :sasl")
                } else {
                    saslDone <- fmt.Errorf("SASL not supported by server")
                }
            case "ACK":
                // When the server acknowledges SASL, send the auth payload once.
                if !authSent {
                    authSent = true
                    // Build the SASL PLAIN payload: username NUL username NUL password.
                    authStr := fmt.Sprintf("%s\x00%s\x00%s", username, username, password)
                    encoded := base64.StdEncoding.EncodeToString([]byte(authStr))
                    conn.SendRaw("AUTHENTICATE " + encoded)
                }
            }
        }
    })

    // If for some reason the server does send a 903, use it.
    conn.AddCallback("903", func(e *ircevent.Event) {
        fmt.Println("SASL 903: Authentication successful.")
        conn.SendRaw("CAP END")
        select {
        case saslDone <- nil:
        default:
        }
    })
    // Callbacks for failures.
    conn.AddCallback("904", func(e *ircevent.Event) {
        saslDone <- fmt.Errorf("SASL authentication failed")
    })
    conn.AddCallback("905", func(e *ircevent.Event) {
        saslDone <- fmt.Errorf("SASL authentication aborted")
    })

    err := conn.Connect(config.Cfg.IRCServer)
    if err != nil {
        return nil, fmt.Errorf("failed to connect to IRC: %w", err)
    }

    go conn.Loop()

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
