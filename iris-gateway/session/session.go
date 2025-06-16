package session

import (
	"encoding/json"
	"log" // Added for logging potential errors
	"sync"
	"time"

	"github.com/gorilla/websocket"
	ircevent "github.com/thoj/go-ircevent"
)

type Message struct {
	From    string    `json:"from"`
	Content string    `json:"content"`
	Time    time.Time `json:"time"`
}

type ChannelState struct {
	Name       string    `json:"name"`
	Members    []string  `json:"members"`
	Messages   []Message `json:"messages"`
	LastUpdate time.Time `json:"last_update"`
	Topic      string    `json:"topic"`
}

type UserSession struct {
	Username   string
	IRC        *ircevent.Connection
	Channels   map[string]*ChannelState
	WebSockets []*websocket.Conn
	Mutex      sync.RWMutex // Protects access to WebSockets slice and Channels map
}

var (
	sessionMap = make(map[string]*UserSession)
	mutex      sync.RWMutex // Protects access to sessionMap
)

func AddSession(token string, s *UserSession) {
	mutex.Lock()
	defer mutex.Unlock()
	sessionMap[token] = s
}

func GetSession(token string) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	s, ok := sessionMap[token]
	return s, ok
}

func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	// Optionally close all WebSockets associated with this session before deleting
	if sess, ok := sessionMap[token]; ok {
		sess.Mutex.Lock()
		for _, conn := range sess.WebSockets {
			conn.Close() // Close each WebSocket
		}
		sess.WebSockets = nil // Clear the slice
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
}

// AddWebSocket adds a new WebSocket connection to the user's session.
func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
}

// RemoveWebSocket removes a disconnected WebSocket from the user's session.
func (s *UserSession) RemoveWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	for i, ws := range s.WebSockets {
		if ws == conn {
			s.WebSockets = append(s.WebSockets[:i], s.WebSockets[i+1:]...)
			break
		}
	}
	// Note: conn.Close() is typically called by the handler goroutine itself
	// or when the connection error/done callback is triggered.
	// You might want to remove the conn.Close() call here if it's handled elsewhere
	// to avoid closing it multiple times. For safety, leaving it for now.
}

// Broadcast sends a real-time event to all WebSocket connections
// associated with this specific UserSession.
func (s *UserSession) Broadcast(eventType string, payload any) {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()

	msg := map[string]any{
		"type":    eventType,
		"payload": payload,
	}

	bytes, err := json.Marshal(msg)
	if err != nil {
		log.Printf("[Session.Broadcast] Error marshalling event '%s': %v", eventType, err)
		return
	}

	for _, ws := range s.WebSockets {
		// Use a goroutine to avoid blocking the broadcast if a client is slow/stalled
		go func(conn *websocket.Conn) {
			if err := conn.WriteMessage(websocket.TextMessage, bytes); err != nil {
				log.Printf("[Session.Broadcast] Error sending to WebSocket for user %s: %v", s.Username, err)
				// Note: You might want to implement a more robust cleanup for broken connections,
				// e.g., by sending a signal back to the WebSocketHandler goroutine to remove it.
				// For now, it will be cleaned up on the next ReadMessage error.
			}
		}(ws)
	}
}

// ForEachSession iterates over all active sessions, calling the provided callback.
// This is crucial for global broadcast events.
func ForEachSession(callback func(s *UserSession)) {
	mutex.RLock()
	defer mutex.RUnlock()
	for _, s := range sessionMap {
		callback(s)
	}
}
