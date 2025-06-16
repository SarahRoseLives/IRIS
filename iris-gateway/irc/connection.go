package irc

import (
    "fmt"
    "time"

    ircevent "github.com/thoj/go-ircevent"
    "iris-gateway/config"
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

    if err := conn.Connect(config.Cfg.IRCServer); err != nil {
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
