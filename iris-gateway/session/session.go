package session

import (
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config" // Import for MaxHistoryLines
	"iris-gateway/events" // Import for RegisterBroadcaster/UnregisterBroadcaster
)

type Message struct {
	From    string    `json:"from"`
	Content string    `json:"content"`
	Time    time.Time `json:"time"`
}

type ChannelState struct {
	Name        string    `json:"name"` // Stores the normalized (lowercased) channel name
	Members     []string  `json:"members"`
	Messages    []Message `json:"messages"`
	LastUpdate  time.Time `json:"last_update"`
	Topic       string    `json:"topic"`
	msgMutex    sync.Mutex // Mutex to protect Messages and Members slices
}

// AddMessage appends a new message to the channel's history,
// ensuring the history does not exceed the configured limit.
func (cs *ChannelState) AddMessage(msg Message) {
	cs.msgMutex.Lock()
	defer cs.msgMutex.Unlock()

	cs.Messages = append(cs.Messages, msg)
	if len(cs.Messages) > config.Cfg.MaxHistoryLines {
		cs.Messages = cs.Messages[len(cs.Messages)-config.Cfg.MaxHistoryLines:]
	}
	cs.LastUpdate = time.Now()
	// New debug log
	log.Printf("[ChannelState.AddMessage] Added msg for '%s' (ptr: %p). Current messages count: %d. Last msg: '%s'",
		cs.Name, cs, len(cs.Messages), msg.Content)
}

// GetMessages returns a copy of the channel's message history.
func (cs *ChannelState) GetMessages() []Message {
    cs.msgMutex.Lock()
    defer cs.msgMutex.Unlock()
    return cs.Messages // Return copy if needed for thread safety
}

type UserSession struct {
	Token      string
	Username   string
	IRC        *ircevent.Connection
	Channels   map[string]*ChannelState // Map key is always the lowercased channel name
	WebSockets []*websocket.Conn
	wsMutex    sync.Mutex   // Mutex to protect WebSocket writes for this session
	Mutex      sync.RWMutex // Protects access to WebSockets slice and Channels map
}

// AddChannelToSession adds or updates a channel's state in the user's session.
// Channel names are normalized to lowercase before being stored as keys.
func (s *UserSession) AddChannelToSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName) // Normalize to lowercase
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if _, ok := s.Channels[normalizedChannelName]; !ok {
		cs := &ChannelState{ // Create a new ChannelState pointer
			Name:        normalizedChannelName, // Store normalized name in the struct
			Members:     []string{},
			Messages:    []Message{},
			LastUpdate:  time.Now(),
		}
		s.Channels[normalizedChannelName] = cs // Assign the new pointer to the map
		// New debug log
		log.Printf("[Session.AddChannelToSession] User %s added new channel '%s' (ptr: %p). Total channels: %d",
			s.Username, normalizedChannelName, cs, len(s.Channels))
	} else {
		// New debug log
		log.Printf("[Session.AddChannelToSession] User %s already has channel '%s' in session (ptr: %p). No new entry created.",
			s.Username, normalizedChannelName, s.Channels[normalizedChannelName])
	}
}

// RemoveChannelFromSession removes a channel's state from the user's session.
// Channel names are normalized to lowercase for lookup.
func (s *UserSession) RemoveChannelFromSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName) // Normalize to lowercase
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if cs, ok := s.Channels[normalizedChannelName]; ok {
		// New debug log
		log.Printf("[Session.RemoveChannelFromSession] Removing channel '%s' (ptr: %p) for user %s. Messages count: %d",
			normalizedChannelName, cs, s.Username, len(cs.Messages))
		delete(s.Channels, normalizedChannelName)
		log.Printf("[Session.RemoveChannelFromSession] User %s removed channel '%s' from session. Total channels: %d", s.Username, normalizedChannelName, len(s.Channels))
	} else {
		log.Printf("[Session.RemoveChannelFromSession] Attempted to remove non-existent channel '%s' for user %s.", normalizedChannelName, s.Username)
	}
}

// UpdateChannelMembers updates the list of members for a given channel.
// Channel names are normalized to lowercase for lookup.
func (s *UserSession) UpdateChannelMembers(channelName string, members []string) {
    normalizedChannelName := strings.ToLower(channelName) // Normalize to lowercase
    s.Mutex.Lock()
    defer s.Mutex.Unlock()

    if ch, ok := s.Channels[normalizedChannelName]; ok {
        ch.msgMutex.Lock() // Protect channel-specific data (Members)
        ch.Members = members
        ch.msgMutex.Unlock() // Release the channel's mutex
        // New debug log
        log.Printf("[Session.UpdateChannelMembers] Channel '%s' (ptr: %p) members updated. Count: %d", normalizedChannelName, ch, len(members))
    } else {
        log.Printf("[Session.UpdateChannelMembers] Attempted to update members for non-existent channel '%s'", normalizedChannelName)
    }
}

// AddMessageToChannel adds a message to the specified channel's history in the session.
// Channel names are normalized to lowercase for lookup.
func (s *UserSession) AddMessageToChannel(channelName, sender, messageContent string) {
    normalizedChannelName := strings.ToLower(channelName) // Normalize to lowercase
    s.Mutex.RLock() // Use RLock for reading the Channels map
    channelState, exists := s.Channels[normalizedChannelName]
    s.Mutex.RUnlock()

    if exists {
        channelState.AddMessage(Message{
            From:    sender,
            Content: messageContent,
            Time:    time.Now(),
        })
        // AddMessage already logs the details, no need for redundant log here unless different info needed
    } else {
        log.Printf("[Session.AddMessageToChannel] Attempted to add message to non-existent channel '%s' (normalized). Message: '%s'", normalizedChannelName, messageContent)
    }
}


var (
	sessionMap = make(map[string]*UserSession)
	mutex      sync.RWMutex // Protects access to sessionMap
)

// AddSession adds a new user session to the map and registers its broadcaster function.
func AddSession(token string, s *UserSession) {
	mutex.Lock()
	defer mutex.Unlock()
	s.Token = token
	sessionMap[token] = s
	events.RegisterBroadcaster(token, s.Broadcast)
	// New debug log
	log.Printf("[Session.AddSession] Session added for user '%s' (token: %s, session_ptr: %p)", s.Username, token, s)
}

func GetSession(token string) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	s, ok := sessionMap[token]
	if ok {
		// New debug log
		log.Printf("[Session.GetSession] Retrieved session for token '%s' (session_ptr: %p)", token, s)
	} else {
		log.Printf("[Session.GetSession] Session not found for token '%s'", token)
	}
	return s, ok
}

// RemoveSession removes a user session.
func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	if sess, ok := sessionMap[token]; ok {
		// New debug log
		log.Printf("[Session.RemoveSession] Preparing to remove session for token '%s' (session_ptr: %p)", token, sess)
		sess.Mutex.Lock()
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
	events.UnregisterBroadcaster(token)
	// New debug log
	log.Printf("[Session.RemoveSession] Session removed for token '%s'", token)
}

func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
	// New debug log
	log.Printf("[Session.AddWebSocket] WebSocket added for user '%s' (session_ptr: %p). Total WS: %d", s.Username, s, len(s.WebSockets))
}

func (s *UserSession) RemoveWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	initialCount := len(s.WebSockets)
	for i, ws := range s.WebSockets {
		if ws == conn {
			s.WebSockets = append(s.WebSockets[:i], s.WebSockets[i+1:]...)
			break
		}
	}
	// New debug log
	log.Printf("[Session.RemoveWebSocket] WebSocket removed for user '%s' (session_ptr: %p). WS count changed from %d to %d", s.Username, s, initialCount, len(s.WebSockets))
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

	// New debug log: Uncomment this if you need to see every broadcast, but it can be noisy.
	// log.Printf("[Session.Broadcast] Broadcasting '%s' to %d WebSockets for user '%s' (session_ptr: %p)", eventType, len(s.WebSockets), s.Username, s)

	for _, ws := range s.WebSockets {
		s.wsMutex.Lock()
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.wsMutex.Unlock()

		if err != nil {
			log.Printf("[Session.Broadcast] Error sending message to WebSocket for user '%s': %v", s.Username, err)
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
