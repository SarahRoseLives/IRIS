package session

import (
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/events"
)

type ChannelMember struct {
	Nick   string `json:"nick"`
	Prefix string `json:"prefix"`
}

type ChannelState struct {
	Name       string          `json:"name"`
	Members    []ChannelMember `json:"members"`
	LastUpdate time.Time       `json:"last_update"`
	mutex      sync.Mutex      `json:"-"` // FIX: Prevent the mutex from being marshalled to JSON.
}

func NewUserSession(username string) *UserSession {
	return &UserSession{
		Username:     username,
		Channels:     make(map[string]*ChannelState),
		pendingNames: make(map[string][]string),
	}
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
	WsMutex      sync.Mutex // FIX: Renamed from wsMutex to be an exported field.
	Mutex        sync.RWMutex
	IsAway       bool
	AwayMessage  string
}

func (s *UserSession) IsActive() bool {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	return len(s.WebSockets) > 0
}

func (s *UserSession) AddChannelToSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if _, ok := s.Channels[normalizedChannelName]; !ok {
		s.Channels[normalizedChannelName] = &ChannelState{
			Name:       normalizedChannelName,
			Members:    []ChannelMember{},
			LastUpdate: time.Now(),
		}
		log.Printf("[Session.AddChannelToSession] User %s added new channel '%s'", s.Username, normalizedChannelName)
	}
}

func (s *UserSession) RemoveChannelFromSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if _, ok := s.Channels[normalizedChannelName]; ok {
		log.Printf("[Session.RemoveChannelFromSession] Removing channel '%s' for user %s.", normalizedChannelName, s.Username)
		delete(s.Channels, normalizedChannelName)
		log.Printf("[Session.RemoveChannelFromSession] User %s removed channel '%s' from session. Total channels: %d", s.Username, normalizedChannelName, len(s.Channels))
	} else {
		log.Printf("[Session.RemoveChannelFromSession] Attempted to remove non-existent channel '%s' for user %s.", normalizedChannelName, s.Username)
	}
}

func (s *UserSession) SyncChannels(channels []string) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	existing := make(map[string]bool)
	for ch := range s.Channels {
		existing[ch] = true
	}

	for _, ch := range channels {
		nc := strings.ToLower(ch)
		if !existing[nc] {
			s.AddChannelToSession(nc)
			log.Printf("[Session] Synced channel %s for %s", nc, s.Username)
		}
	}
}

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
		channelState.mutex.Lock()
		channelState.Members = parsedMembers
		channelState.LastUpdate = time.Now()
		channelState.mutex.Unlock()
		log.Printf("[Session.FinalizeChannelMembers] Finalized %d members for channel '%s'", len(parsedMembers), normalizedChannelName)

		go s.Broadcast("members_update", map[string]interface{}{
			"channel_name": normalizedChannelName,
			"members":      parsedMembers,
		})
	} else {
		log.Printf("[Session.FinalizeChannelMembers] Channel '%s' not found in session.", normalizedChannelName)
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

func (s *UserSession) Broadcast(eventType string, payload any) {
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
		s.WsMutex.Lock() // FIX: Use the exported WsMutex
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.WsMutex.Unlock() // FIX: Use the exported WsMutex

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

func (s *UserSession) SetAway(message string) {
	s.Mutex.Lock()
	s.IsAway = true
	s.AwayMessage = message
	if s.IRC != nil {
		s.IRC.SendRawf("AWAY :%s", message)
	}
	s.Mutex.Unlock() // PATCH: Release lock before broadcasting to prevent deadlock.

	s.Broadcast("user_away", map[string]string{
		"username": s.Username,
		"message":  message,
	})
}

func (s *UserSession) SetBack() {
	s.Mutex.Lock()
	s.IsAway = false
	s.AwayMessage = ""
	if s.IRC != nil {
		s.IRC.SendRaw("BACK")
	}
	s.Mutex.Unlock() // PATCH: Release lock before broadcasting to prevent deadlock.

	s.Broadcast("user_back", map[string]string{
		"username": s.Username,
	})
}