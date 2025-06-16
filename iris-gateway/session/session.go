package session

import (
    "sync"
    "time"

    ircevent "github.com/thoj/go-ircevent"
)

// Message represents an IRC message.
type Message struct {
    From    string    `json:"from"`
    Content string    `json:"content"`
    Time    time.Time `json:"time"`
}

// ChannelState represents the state of a joined channel.
type ChannelState struct {
    Name       string    `json:"name"`
    Members    []string  `json:"members"`
    Messages   []Message `json:"messages"`
    LastUpdate time.Time `json:"last_update"`
}

// UserSession holds data about an IRC-connected user and their channels.
type UserSession struct {
    Username string
    IRC      *ircevent.Connection
    Channels map[string]*ChannelState
    Mutex    sync.RWMutex
}

var (
    sessionMap = make(map[string]*UserSession)
    mutex      sync.RWMutex
)

// AddSession registers a session under a token.
func AddSession(token string, s *UserSession) {
    mutex.Lock()
    defer mutex.Unlock()
    sessionMap[token] = s
}

// GetSession retrieves a session by token.
func GetSession(token string) (*UserSession, bool) {
    mutex.RLock()
    defer mutex.RUnlock()
    s, ok := sessionMap[token]
    return s, ok
}

// RemoveSession deletes a session by token.
func RemoveSession(token string) {
    mutex.Lock()
    defer mutex.Unlock()
    delete(sessionMap, token)
}
