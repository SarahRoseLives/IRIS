package session

import (
	"encoding/json"
	"log"
	"strings"
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
	wsMutex    sync.Mutex   // Mutex to protect WebSocket writes for this session
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
	if sess, ok := sessionMap[token]; ok {
		sess.Mutex.Lock()
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
}

func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
}

func (s *UserSession) RemoveWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	for i, ws := range s.WebSockets {
		if ws == conn {
			s.WebSockets = append(s.WebSockets[:i], s.WebSockets[i+1:]...)
			break
		}
	}
	// conn.Close() should be handled elsewhere (usually in the reader goroutine)
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
		// Protect all writes to WebSockets with a single wsMutex to prevent concurrent WriteMessage calls.
		s.wsMutex.Lock()
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.wsMutex.Unlock()

		if err != nil {
			log.Printf("[Session.Broadcast] Error sending message to WebSocket for user %s: %v", s.Username, err)
			// Do not close connection here to avoid deadlocks; defer in reader goroutine handles cleanup.
		}
	}
}

// ForEachSession iterates over all active sessions, calling the provided callback.
func ForEachSession(callback func(s *UserSession)) {
	mutex.RLock()
	defer mutex.RUnlock()
	for _, s := range sessionMap {
		callback(s)
	}
}

// FindSessionTokenByUsername returns the first session token matching the username (case-insensitive).
func FindSessionTokenByUsername(username string) (string, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	for token, sess := range sessionMap {
		if strings.EqualFold(sess.Username, username) {
			return token, true
		}
	}
	return "", false
}
