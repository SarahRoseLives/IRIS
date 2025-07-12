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
	"fmt" // Add fmt import here
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
	Mutex      sync.RWMutex    `json:"-"` // Changed to RWMutex
}

// UserNetwork represents a single IRC network configuration for a user.
type UserNetwork struct {
	ID              int                  `json:"id"` // Unique ID for the network config
	UserID          int                  `json:"user_id"`
	NetworkName     string               `json:"network_name"`
	Hostname        string               `json:"hostname"`
	Port            int                  `json:"port"`
	UseSSL          bool                 `json:"use_ssl"`
	ServerPassword  string               `json:"server_password,omitempty"` // Omitted in JSON for security
	AutoReconnect   bool                 `json:"auto_reconnect"`
	Modules         []string             `json:"modules"`          // e.g., ["sasl", "nickserv"]
	PerformCommands []string             `json:"perform_commands"` // Commands to run on connect
	InitialChannels []string             `json:"initial_channels"` // Channels to join on connect
	Nickname        string               `json:"nickname"`
	AltNickname     string               `json:"alt_nickname"`
	Ident           string               `json:"ident"` // Username
	Realname        string               `json:"realname"`
	QuitMessage     string               `json:"quit_message"`

	// Live connection details
	IRC            *ircevent.Connection       `json:"-"` // Actual IRC connection, not marshaled
	IsConnected    bool                       `json:"is_connected"`
	IsConnecting   bool                       `json:"-"` // Track connection attempts
	Channels       map[string]*ChannelState   `json:"channels"` // Channels for this specific network

	// Mutex for this specific network's state
	Mutex sync.RWMutex `json:"-"`

	ReconnectAttempts int         `json:"-"` // Tracks consecutive reconnect attempts
	ReconnectTimer    *time.Timer `json:"-"` // Timer for exponential backoff reconnects
}

type UserSession struct {
	Token       string
	Username    string
	Password    string
	FCMToken    string
	WebSockets  []*websocket.Conn
	WsMutex     sync.Mutex
	Mutex       sync.RWMutex
	IsAway      bool
	AwayMessage string
	UserID      int // Added UserID to UserSession

	// Map of network ID to UserNetwork for this session
	// This will hold the *live* IRC connections and their states
	Networks map[int]*UserNetwork
}

func NewUserSession(username string) *UserSession {
	return &UserSession{
		Username: username,
		Networks: make(map[int]*UserNetwork), // Initialize the networks map
	}
}

func (s *UserSession) IsActive() bool {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	return len(s.WebSockets) > 0
}

// AddWebSocket adds a WebSocket connection to the session.
func (s *UserSession) AddWebSocket(conn *websocket.Conn) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.WebSockets = append(s.WebSockets, conn)
}

// RemoveWebSocket removes a WebSocket connection from the session.
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

// Broadcast sends a WebSocket event to all active WebSocket connections for this user.
func (s *UserSession) Broadcast(eventType string, payload any) {
	msg := events.WsEvent{
		Type:    eventType,
		Payload: payload,
	}
	bytes, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Error marshaling event %s: %v", eventType, err)
		return
	}

	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	for _, ws := range s.WebSockets {
		s.WsMutex.Lock() // Lock individual websocket for writing
		err := ws.WriteMessage(websocket.TextMessage, bytes)
		s.WsMutex.Unlock()
		if err != nil {
			log.Printf("Error writing to WebSocket for user %s: %v", s.Username, err)
			// TODO: Handle broken connections (e.g., remove from list)
		}
	}
}

// ForEachSession iterates over all active user sessions.
func ForEachSession(callback func(s *UserSession)) {
	mutex.RLock()
	defer mutex.RUnlock()
	for _, s := range sessionMap {
		callback(s)
	}
}

// FindSessionTokenByUsername finds an existing session token for a given username.
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
	sess, found := sessionMap[token]
	return sess, found
}

// RemoveSession cleans up all resources associated with a session, including IRC connections.
func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	if sess, ok := sessionMap[token]; ok {
		sess.Mutex.Lock()
		defer sess.Mutex.Unlock()

		// Close all WebSocket connections gracefully
		for _, conn := range sess.WebSockets {
			conn.Close()
		}
		sess.WebSockets = nil

		// Disconnect all IRC connections
		for _, netConfig := range sess.Networks {
			if netConfig.IRC != nil {
				log.Printf("Disconnecting IRC for user %s, network %s", sess.Username, netConfig.NetworkName)
				netConfig.IRC.Quit()
				// The ircevent library usually closes the underlying connection after Quit
				// but adding a Disconnect call if available on the type is safer.
				if disconnecter, ok := interface{}(netConfig.IRC).(interface{ Disconnect() }); ok {
					disconnecter.Disconnect()
				}
				netConfig.IRC = nil
				netConfig.IsConnected = false
			}
		}
		delete(sessionMap, token)
	}
}

// UnmapToken only removes the token from the session map, it does not close connections.
// This is used when re-issuing a token for an existing session.
func UnmapToken(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	delete(sessionMap, token)
}

// SetAway sends an AWAY message to all connected IRC networks for the user.
func (s *UserSession) SetAway(message string) {
	s.Mutex.Lock()
	s.IsAway = true
	s.AwayMessage = message
	for _, netConfig := range s.Networks {
		if netConfig.IRC != nil && netConfig.IsConnected {
			netConfig.IRC.SendRawf("AWAY :%s", message)
		}
	}
	s.Mutex.Unlock()
	s.Broadcast("user_away", map[string]string{
		"username": s.Username,
		"message":  message,
	})
}

// SetBack sends a BACK message to all connected IRC networks for the user.
func (s *UserSession) SetBack() {
	s.Mutex.Lock()
	s.IsAway = false
	s.AwayMessage = ""
	for _, netConfig := range s.Networks {
		if netConfig.IRC != nil && netConfig.IsConnected {
			netConfig.IRC.SendRaw("BACK")
		}
	}
	s.Mutex.Unlock()
	s.Broadcast("user_back", map[string]string{
		"username": s.Username,
	})
}

// --- Methods for managing channels and members within a specific network ---

// GetNetwork returns a specific UserNetwork configuration for the session.
func (s *UserSession) GetNetwork(networkID int) (*UserNetwork, bool) {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()
	netConfig, ok := s.Networks[networkID]
	return netConfig, ok
}

// AddChannelToNetwork adds a channel to a specific network's state for the user.
func (un *UserNetwork) AddChannelToNetwork(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	un.Mutex.Lock()
	defer un.Mutex.Unlock()

	if un.Channels == nil {
		un.Channels = make(map[string]*ChannelState)
	}

	if _, ok := un.Channels[normalizedChannelName]; !ok {
		un.Channels[normalizedChannelName] = &ChannelState{
			Name:       channelName,
			Topic:      "",
			Members:    []ChannelMember{},
			LastUpdate: time.Now(),
		}
	}
}

// RemoveChannelFromNetwork removes a channel from a specific network's state for the user.
func (un *UserNetwork) RemoveChannelFromNetwork(channelName string) {
	normalizedChannelName := strings.ToLower(channelName)
	un.Mutex.Lock()
	defer un.Mutex.Unlock()
	if un.Channels != nil {
		delete(un.Channels, normalizedChannelName)
	}
}

// SetChannelTopic safely updates the topic for a single channel within a specific network.
func (un *UserNetwork) SetChannelTopic(channelName, topic string) {
	normalizedChannelName := strings.ToLower(channelName)
	un.Mutex.RLock()
	channelState, exists := un.Channels[normalizedChannelName]
	un.Mutex.RUnlock()

	if exists {
		channelState.Mutex.Lock()
		channelState.Topic = topic
		channelState.LastUpdate = time.Now()
		channelState.Mutex.Unlock()
	}
}

// --- Accumulate and Finalize Members (modified to be per-network) ---

// A temporary map to hold pending NAMES replies for each network.
// Key: networkID_channelName (e.g., "1_#general")
var pendingNamesByNetwork = struct {
	sync.Mutex
	m map[string][]string
}{m: make(map[string][]string)}

func (un *UserNetwork) AccumulateChannelMembers(channelName string, members []string) {
	key := fmt.Sprintf("%d_%s", un.ID, strings.ToLower(channelName))
	pendingNamesByNetwork.Lock()
	defer pendingNamesByNetwork.Unlock()

	pendingNamesByNetwork.m[key] = append(pendingNamesByNetwork.m[key], members...)
}

func (un *UserNetwork) FinalizeChannelMembers(channelName string) {
	key := fmt.Sprintf("%d_%s", un.ID, strings.ToLower(channelName))
	pendingNamesByNetwork.Lock()
	rawMembers, ok := pendingNamesByNetwork.m[key]
	if !ok {
		pendingNamesByNetwork.Unlock()
		return
	}
	delete(pendingNamesByNetwork.m, key)
	pendingNamesByNetwork.Unlock()

	parsedMembers := make([]ChannelMember, 0, len(rawMembers))
	validPrefixes := "~&@%+" // IRC channel prefixes
	for _, rawNick := range rawMembers {
		if rawNick == "" {
			continue
		}
		prefix := ""
		nick := rawNick
		if len(rawNick) > 0 && strings.ContainsRune(validPrefixes, rune(rawNick[0])) {
			prefix = string(rawNick[0])
			nick = rawNick[1:]
		}
		// TODO: Implement away status tracking for members if the IRC server supports it (e.g. AWAY-NOTIFY)
		parsedMembers = append(parsedMembers, ChannelMember{Nick: nick, Prefix: prefix, IsAway: false})
	}

	un.Mutex.Lock() // Use un's RWMutex for its Channels map
	channelState, exists := un.Channels[strings.ToLower(channelName)]
	un.Mutex.Unlock()

	if exists {
		channelState.Mutex.Lock() // Use channelState's RWMutex
		channelState.Members = parsedMembers
		channelState.LastUpdate = time.Now()
		channelState.Mutex.Unlock()

		// Broadcast to all clients of this specific user session
		// The event payload should include the network ID for the client to know which network this update belongs to.
		sess, found := GetSessionByUserID(un.UserID)
		if found {
			sess.Broadcast(events.EventTypeMembersUpdate, map[string]interface{}{
				"network_id":   un.ID, // Add network ID
				"channel_name": channelName,
				"members":      parsedMembers,
			})
		}
	}
}

// UpdateAwayStatusForNetworkMember updates the away status of a user in all channels of a specific network.
func (un *UserNetwork) UpdateAwayStatusForNetworkMember(nick string, isAway bool) {
	un.Mutex.Lock()
	defer un.Mutex.Unlock()

	channelsToBroadcast := []string{}

	for chName, chState := range un.Channels {
		chState.Mutex.Lock() // Use channelState's RWMutex
		updated := false
		for i := range chState.Members {
			if strings.EqualFold(chState.Members[i].Nick, nick) {
				if chState.Members[i].IsAway != isAway {
					chState.Members[i].IsAway = isAway
					updated = true
				}
				break
			}
		}
		chState.Mutex.Unlock() // Use channelState's RWMutex
		if updated {
			channelsToBroadcast = append(channelsToBroadcast, chName)
		}
	}

	// Broadcast updates to clients of this specific user session
	sess, found := GetSessionByUserID(un.UserID)
	if found {
		for _, chName := range channelsToBroadcast {
			if chState, ok := un.Channels[strings.ToLower(chName)]; ok {
				chState.Mutex.RLock() // Use channelState's RWMutex
				membersCopy := make([]ChannelMember, len(chState.Members))
				copy(membersCopy, chState.Members)
				chState.Mutex.RUnlock() // Use channelState's RWMutex

				sess.Broadcast(events.EventTypeMembersUpdate, map[string]interface{}{
					"network_id":   un.ID,
					"channel_name": chName,
					"members":      membersCopy,
				})
			}
		}
	}
}

// GetSessionByUserID is a helper function to retrieve a UserSession by UserID.
// This is needed because `sessionMap` is keyed by token, not UserID.
// This might be inefficient for many users and could be optimized with another map.
func GetSessionByUserID(userID int) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	for _, sess := range sessionMap {
		// Assuming Username can be mapped back to UserID from users.User
		// For now, we'll just check if the username exists in any session.
		// A proper implementation would likely need a map[int]*UserSession.
		// For this refactor, we'll assume `users.GetUserByUsername` can fetch the ID.
		// This will require modifying `UserSession` to store `UserID`.
		// (Assuming `sess.UserID` is now populated during login)
		if sess.UserID == userID {
			return sess, true
		}
	}
	return nil, false
}

// Add UserID to UserSession to enable GetSessionByUserID
func (s *UserSession) SetUserID(id int) {
	s.UserID = id
}

// ReconnectNetwork is a placeholder to resolve circular dependency.
// The actual reconnection logic is orchestrated in handlers/irc_networks.go
// This method serves to allow irc_client.go to trigger a reconnection attempt
// on the session object, which then calls the handler.
func (s *UserSession) ReconnectNetwork(networkID int) {
	// This function is intentionally left empty here to break a circular dependency
	// between session and handlers/irc_networks. The actual re-connection logic
	// is now handled by a dedicated function in handlers/irc_networks.go,
	// which can be called by irc_client.go via a function reference passed during
	// connection establishment, or by looking up the session.
	// For now, this is a no-op that satisfies the interface requirement if any.
	// The primary trigger for auto-reconnect will be the DISCONNECT callback in irc_client.go
	// which will call the public ReconnectNetwork function in handlers.
}