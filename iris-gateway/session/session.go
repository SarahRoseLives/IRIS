// session/session.go
package session

import (
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/events"
)

// ChannelMember struct holds the nickname and their IRC status prefix.
type ChannelMember struct {
	Nick   string `json:"nick"`
	Prefix string `json:"prefix"`
}

type Message struct {
	From    string    `json:"from"`
	Content string    `json:"content"`
	Time    time.Time `json:"time"`
}

type ChannelState struct {
	Name       string          `json:"name"`
	Members    []ChannelMember `json:"members"`
	Messages   []Message       `json:"messages"`
	LastUpdate time.Time       `json:"last_update"`
	Topic      string          `json:"topic"`
	msgMutex   sync.Mutex
}

func (cs *ChannelState) AddMessage(msg Message) {
	cs.msgMutex.Lock()
	defer cs.msgMutex.Unlock()

	cs.Messages = append(cs.Messages, msg)
	if len(cs.Messages) > config.Cfg.MaxHistoryLines {
		cs.Messages = cs.Messages[len(cs.Messages)-config.Cfg.MaxHistoryLines:]
	}
	cs.LastUpdate = time.Now()
	log.Printf("[ChannelState.AddMessage] Added msg for '%s' (ptr: %p). Current messages count: %d. Last msg: '%s'",
		cs.Name, cs, len(cs.Messages), msg.Content)
}

func (cs *ChannelState) GetMessages() []Message {
	cs.msgMutex.Lock()
	defer cs.msgMutex.Unlock()
	messagesCopy := make([]Message, len(cs.Messages))
	copy(messagesCopy, cs.Messages)
	return messagesCopy
}

type UserSession struct {
	Token        string
	Username     string
	FCMToken     string
	IRC          *ircevent.Connection
	Channels     map[string]*ChannelState
	pendingNames map[string][]string
	namesMutex   sync.Mutex
	WebSockets   []*websocket.Conn
	wsMutex      sync.Mutex
	Mutex        sync.RWMutex
	// NEW: Flag to indicate if the session is still syncing initial history
	isSyncing bool
}

// NEW: Constructor to initialize a UserSession with isSyncing set to true.
func NewUserSession(username string) *UserSession {
	return &UserSession{
		Username:     username,
		Channels:     make(map[string]*ChannelState),
		pendingNames: make(map[string][]string),
		isSyncing:    true, // Start in syncing state by default
	}
}

// NEW: Method to set the syncing status in a thread-safe way.
func (s *UserSession) SetSyncing(syncing bool) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.isSyncing = syncing
	if !syncing {
		log.Printf("[Session] User %s has completed initial history sync.", s.Username)
	}
}

// IsActive checks if the user has any active WebSocket connections.
func (s *UserSession) IsActive() bool {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	return len(s.WebSockets) > 0
}

// AddChannelToSession adds or updates a channel's state in the user's session.
func (s *UserSession) AddChannelToSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if _, ok := s.Channels[normalizedChannelName]; !ok {
		cs := &ChannelState{
			Name:       normalizedChannelName,
			Members:    []ChannelMember{},
			Messages:   []Message{},
			LastUpdate: time.Now(),
		}
		s.Channels[normalizedChannelName] = cs
		log.Printf("[Session.AddChannelToSession] User %s added new channel '%s' (ptr: %p). Total channels: %d",
			s.Username, normalizedChannelName, cs, len(s.Channels))
	} else {
		log.Printf("[Session.AddChannelToSession] User %s already has channel '%s' in session (ptr: %p). No new entry created.",
			s.Username, normalizedChannelName, s.Channels[normalizedChannelName])
	}
}

// RemoveChannelFromSession removes a channel's state from the user's session.
func (s *UserSession) RemoveChannelFromSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if cs, ok := s.Channels[normalizedChannelName]; ok {
		log.Printf("[Session.RemoveChannelFromSession] Removing channel '%s' (ptr: %p) for user %s. Messages count: %d",
			normalizedChannelName, cs, s.Username, len(cs.Messages))
		delete(s.Channels, normalizedChannelName)
		log.Printf("[Session.RemoveChannelFromSession] User %s removed channel '%s' from session. Total channels: %d", s.Username, normalizedChannelName, len(s.Channels))
	} else {
		log.Printf("[Session.RemoveChannelFromSession] Attempted to remove non-existent channel '%s' for user %s.", normalizedChannelName, s.Username)
	}
}

// AccumulateChannelMembers stores raw member lists from 353 replies temporarily.
func (s *UserSession) AccumulateChannelMembers(channelName string, members []string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.namesMutex.Lock()
	defer s.namesMutex.Unlock()

	if s.pendingNames == nil {
		s.pendingNames = make(map[string][]string)
	}

	s.pendingNames[normalizedChannelName] = append(s.pendingNames[normalizedChannelName], members...)
	log.Printf("[Session.AccumulateChannelMembers] Accumulated %d members for '%s'. Total pending: %d", len(members), normalizedChannelName, len(s.pendingNames[normalizedChannelName]))
}

// FinalizeChannelMembers processes the accumulated members and updates the channel state.
func (s *UserSession) FinalizeChannelMembers(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.namesMutex.Lock()
	rawMembers, ok := s.pendingNames[normalizedChannelName]
	if !ok {
		s.namesMutex.Unlock()
		log.Printf("[Session.FinalizeChannelMembers] No pending members for channel '%s'", normalizedChannelName)
		return
	}
	delete(s.pendingNames, normalizedChannelName)
	s.namesMutex.Unlock()

	parsedMembers := make([]ChannelMember, 0, len(rawMembers))
	validPrefixes := "~&@%+"
	for _, rawNick := range rawMembers {
		if rawNick == "" {
			continue
		}
		prefix := ""
		nick := rawNick
		if strings.ContainsRune(validPrefixes, rune(rawNick[0])) {
			prefix = string(rawNick[0])
			nick = rawNick[1:]
		}
		parsedMembers = append(parsedMembers, ChannelMember{Nick: nick, Prefix: prefix})
	}

	s.Mutex.Lock()
	channelState, exists := s.Channels[normalizedChannelName]
	s.Mutex.Unlock()

	if exists {
		channelState.msgMutex.Lock()
		channelState.Members = parsedMembers
		channelState.LastUpdate = time.Now()
		channelState.msgMutex.Unlock()
		log.Printf("[Session.FinalizeChannelMembers] Finalized %d members for channel '%s'", len(parsedMembers), normalizedChannelName)

		go s.Broadcast("members_update", map[string]interface{}{
			"channel_name": normalizedChannelName,
			"members":      parsedMembers,
		})
	} else {
		log.Printf("[Session.FinalizeChannelMembers] Channel '%s' not found in session.", normalizedChannelName)
	}
}

// AddMessageToChannel adds a message to the specified channel's history in the session.
func (s *UserSession) AddMessageToChannel(channelName, sender, messageContent string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.RLock()
	channelState, exists := s.Channels[normalizedChannelName]
	s.Mutex.RUnlock()

	if exists {
		channelState.AddMessage(Message{
			From:    sender,
			Content: messageContent,
			Time:    time.Now(),
		})
	} else {
		log.Printf("[Session.AddMessageToChannel] Attempted to add message to non-existent channel '%s'", normalizedChannelName)
	}
}

var (
	sessionMap = make(map[string]*UserSession)
	mutex      = sync.RWMutex{}
)

func AddSession(token string, s *UserSession) {
	mutex.Lock()
	defer mutex.Unlock()
	s.Token = token
	sessionMap[token] = s
	log.Printf("[Session.AddSession] Session added for user '%s' (token: %s, session_ptr: %p)", s.Username, token, s)
}

func GetSession(token string) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	s, ok := sessionMap[token]
	if ok {
		log.Printf("[Session.GetSession] Retrieved session for token '%s' (session_ptr: %p)", token, s)
	} else {
		log.Printf("[Session.GetSession] Session not found for token '%s'", token)
	}
	return s, ok
}

func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	if sess, ok := sessionMap[token]; ok {
		log.Printf("[Session.RemoveSession] Preparing to remove session for token '%s' (session_ptr: %p)", token, sess)
		sess.Mutex.Lock()
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
	log.Printf("[Session.RemoveSession] Session removed for token '%s'", token)
}

func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
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
	log.Printf("[Session.RemoveWebSocket] WebSocket removed for user '%s' (session_ptr: %p). WS count changed from %d to %d", s.Username, s, initialCount, len(s.WebSockets))
}

// MODIFIED: The Broadcast method now contains the sync check.
func (s *UserSession) Broadcast(eventType string, payload any) {
	s.Mutex.RLock()
	// CRITICAL CHANGE: If the session is syncing, DO NOT broadcast real-time messages.
	// The client will get these messages as part of the initial history dump.
	if s.isSyncing && eventType == "message" {
		log.Printf("[Session.Broadcast] Skipping message broadcast for user '%s' (syncing)", s.Username)
		s.Mutex.RUnlock() // Release lock before returning
		return
	}
	s.Mutex.RUnlock() // Release lock after check

	msg := events.WsEvent{
		Type:    eventType,
		Payload: payload,
	}

	bytes, err := json.Marshal(msg)
	if err != nil {
		log.Printf("[Session.Broadcast] Error marshalling event '%s': %v", eventType, err)
		return
	}

	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	for _, ws := range s.WebSockets {
		s.wsMutex.Lock()
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.wsMutex.Unlock()

		if err != nil {
			log.Printf("[Session.Broadcast] Error sending message to WebSocket for user '%s': %v", s.Username, err)
		}
	}
}

func ForEachSession(callback func(s *UserSession)) {
	mutex.RLock()
	defer mutex.RUnlock()
	for _, s := range sessionMap {
		callback(s)
	}
}

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