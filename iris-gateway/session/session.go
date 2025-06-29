package session

import (
	"strings"
	"sync"
	"time"
	"encoding/json"

	"github.com/gorilla/websocket"
	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/events"
)

type ChannelMember struct {
	Nick   string `json:"nick"`
	Prefix string `json:"prefix"`
	IsAway bool   `json:"is_away"`
}

type ChannelState struct {
	Name       string          `json:"name"`
	Topic      string          `json:"topic"`
	Members    []ChannelMember `json:"members"`
	LastUpdate time.Time       `json:"last_update"`
	Mutex      sync.Mutex      `json:"-"`
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
	Password     string
	FCMToken     string
	IRC          *ircevent.Connection
	Channels     map[string]*ChannelState
	pendingNames map[string][]string
	namesMutex   sync.Mutex
	WebSockets   []*websocket.Conn
	WsMutex      sync.Mutex
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
			Name:       channelName,
			Topic:      "",
			Members:    []ChannelMember{},
			LastUpdate: time.Now(),
		}
	}
}

func (s *UserSession) RemoveChannelFromSession(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	delete(s.Channels, normalizedChannelName)
}

func (s *UserSession) AccumulateChannelMembers(channelName string, members []string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.namesMutex.Lock()
	defer s.namesMutex.Unlock()

	if s.pendingNames == nil {
		s.pendingNames = make(map[string][]string)
	}
	s.pendingNames[normalizedChannelName] = append(s.pendingNames[normalizedChannelName], members...)
}

func (s *UserSession) FinalizeChannelMembers(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	s.namesMutex.Lock()
	rawMembers, ok := s.pendingNames[normalizedChannelName]
	if !ok {
		s.namesMutex.Unlock()
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
		parsedMembers = append(parsedMembers, ChannelMember{Nick: nick, Prefix: prefix, IsAway: false})
	}

	s.Mutex.Lock()
	channelState, exists := s.Channels[normalizedChannelName]
	s.Mutex.Unlock()

	if exists {
		channelState.Mutex.Lock()
		channelState.Members = parsedMembers
		channelState.LastUpdate = time.Now()
		channelState.Mutex.Unlock()

		go s.Broadcast("members_update", map[string]interface{}{
			"channel_name": normalizedChannelName,
			"members":      parsedMembers,
		})
	}
}

func UpdateAwayStatusForAllSessions(nick string, isAway bool) {
	mutex.RLock()
	defer mutex.RUnlock()

	for _, s := range sessionMap {
		channelsToUpdate := make([]string, 0)
		s.Mutex.RLock()
		for chName, chState := range s.Channels {
			chState.Mutex.Lock()
			memberUpdated := false
			for i := range chState.Members {
				if strings.EqualFold(chState.Members[i].Nick, nick) {
					chState.Members[i].IsAway = isAway
					memberUpdated = true
					break
				}
			}
			chState.Mutex.Unlock()
			if memberUpdated {
				channelsToUpdate = append(channelsToUpdate, chName)
			}
		}
		s.Mutex.RUnlock()

		for _, chName := range channelsToUpdate {
			s.Mutex.RLock()
			channelState := s.Channels[chName]
			s.Mutex.RUnlock()

			if channelState != nil {
				channelState.Mutex.Lock()
				finalMembers := make([]ChannelMember, len(channelState.Members))
				copy(finalMembers, channelState.Members)
				channelState.Mutex.Unlock()

				go s.Broadcast("members_update", map[string]interface{}{
					"channel_name": chName,
					"members":      finalMembers,
				})
			}
		}
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
}

func GetSession(token string) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	return sessionMap[token], sessionMap[token] != nil
}

// Revised RemoveSession for proper cleanup of websockets and IRC connections
func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	if sess, ok := sessionMap[token]; ok {
		sess.Mutex.Lock()
		// Close all WebSocket connections gracefully
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil

		// Properly disconnect IRC
		if sess.IRC != nil {
			sess.IRC.Quit()        // Send QUIT command to IRC server
			// If IRCClient wrapper with Disconnect exists, call Disconnect
			if disconnecter, ok := interface{}(sess.IRC).(interface{ Disconnect() }); ok {
				disconnecter.Disconnect()
			} else if connField := getIRCConn(sess.IRC); connField != nil {
				connField.Close() // fallback: close IRC TCP connection if accessible
			}
			sess.IRC = nil
		}
		sess.Mutex.Unlock()
	}
	delete(sessionMap, token)
}

// --- ADDED: UnmapToken ---
// UnmapToken only removes the token from the session map, it does not close connections.
// This is used when re-issuing a token for an existing session.
func UnmapToken(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	delete(sessionMap, token)
}

// Helper: attempt to get the Conn field from ircevent.Connection
func getIRCConn(irc *ircevent.Connection) (connCloser interface{ Close() error }) {
	// This is a hacky fallback for legacy ircevent.Connection, not needed if you use IRCClient with Disconnect
	type connField struct {
		Conn interface{ Close() error }
	}
	cf, ok := any(irc).(*connField)
	if ok {
		return cf.Conn
	}
	return nil
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
}

func (s *UserSession) Broadcast(eventType string, payload any) {
	msg := events.WsEvent{
		Type:    eventType,
		Payload: payload,
	}
	bytes, err := json.Marshal(msg)
	if err != nil {
		return
	}
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	for _, ws := range s.WebSockets {
		s.WsMutex.Lock()
		ws.WriteMessage(websocket.TextMessage, bytes)
		s.WsMutex.Unlock()
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
	s.Mutex.Unlock()
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
	s.Mutex.Unlock()
	s.Broadcast("user_back", map[string]string{
		"username": s.Username,
	})
}