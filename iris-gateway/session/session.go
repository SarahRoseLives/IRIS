package session

import (
	"encoding/json"
	"log"
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
	wsMutex    sync.Mutex // NEW: Mutex to protect WebSocket writes for this session
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
		sess.Mutex.Lock() // Lock session's general mutex
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
}

func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock() // Protect the slice modification
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
}

func (s *UserSession) RemoveWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock() // Protect the slice modification
	defer s.Mutex.Unlock()
	for i, ws := range s.WebSockets {
		if ws == conn {
			s.WebSockets = append(s.WebSockets[:i], s.WebSockets[i+1:]...)
			break
		}
	}
	// conn.Close() is typically handled by the reader goroutine defer
}

// Broadcast sends a real-time event to all WebSocket connections
// associated with this specific UserSession.
func (s *UserSession) Broadcast(eventType string, payload any) {
	s.Mutex.RLock() // Read lock for accessing WebSockets slice
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
		// NEW: Protect each WebSocket connection's write operations with its own mutex
		// This ensures only one goroutine writes to a specific 'ws' connection at a time.
		// Note: The wsMutex should be part of the WebSocket connection struct itself,
		// but since we're using raw *websocket.Conn, we'll use the session's wsMutex for simplicity.
		// This is less ideal if a session has many WS connections, but works for common cases.
		// A more robust solution would be to wrap websocket.Conn in a custom struct that holds its mutex.

		// However, the *panic* suggests the core issue is multiple places
		// trying to acquire the *same* conn's write lock, or writing without any lock.
		// The UserSession.wsMutex should protect writes across *all* its websockets for simplicity.
		// Let's protect the write operation itself for each connection.

		// Simpler fix: send directly and rely on gorilla's internal queue or defer conn.Close on error.
		// The panic is from gorilla/websocket trying to flush its internal buffer while another write is ongoing.
		// This implies multiple goroutines are calling WriteMessage on the same 'ws' without external sync.
		// The fix is to ensure the `go func(conn *websocket.Conn)` is safe.

		// The best way to fix this is to either:
		// 1. Give each `*websocket.Conn` a dedicated writer goroutine. (More complex)
		// 2. Protect writes to each `*websocket.Conn` with a mutex that is *part of the connection itself*.
		//    Since we don't control *websocket.Conn directly, we have to protect it externally.
		//    The simplest way for a raw *websocket.Conn is to use its own .NextWriter() method, or a wrapper.

		// Given the panic source is `flushFrame`, it's definitely concurrent WriteMessage calls.
		// The `go func(conn *websocket.Conn)` in the for loop means *all* broadcasts are concurrent.
		// This means `session.Broadcast` is inherently unsafe as it launches many concurrent writes.

		// Corrected approach: Queue messages for each WebSocket
		// This requires a more substantial refactor.
		// For now, let's try a simpler fix for the panic by ensuring Broadcast itself doesn't cause it.
		// The panic is likely from the main reader goroutine also trying to write (e.g. welcome message)
		// and the broadcast goroutines writing.

		// Let's modify the `UserSession` to contain a mutex for its WebSockets list.
		// And ensure that *every* write operation on any of `s.WebSockets` is locked.

		// This implies that `UserSession` needs a mutex *per connection*.
		// Since we don't have that, we can use `s.wsMutex` to serialize all writes for this session.
		// This means only one message can be broadcast at a time per session, but prevents panics.

		s.wsMutex.Lock() // Lock to ensure only one goroutine writes to *any* WS in this session at a time
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.wsMutex.Unlock() // Unlock after writing

		if err != nil {
			log.Printf("[Session.Broadcast] Error sending message to WebSocket for user %s: %v", s.Username, err)
			// No explicit conn.Close() here, as it can cause deadlocks if reader is also trying to close.
			// The reader goroutine's defer takes care of cleanup.
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
