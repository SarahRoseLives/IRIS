package handlers

import (
	"log"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"iris-gateway/session"
	"iris-gateway/users"
	"iris-gateway/irc" // Import irc for connection establishment
	"iris-gateway/events" // Import events for broadcasting connection status
)

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	Token   string `json:"token,omitempty"`
	// Consider adding initial network list here, or make it a separate API call
}

func LoginHandler(c *gin.Context) {
	var req LoginRequest
	if err := c.BindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid JSON"})
		return
	}

	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" || req.Password == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Username and password required"})
		return
	}

	// Step 1: Authenticate the user against the SQLite database
	user, err := users.AuthenticateUser(req.Username, req.Password)
	if err != nil {
		log.Printf("Authentication failed for user '%s': %v", req.Username, err)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid username or password"})
		return
	}
	if user.IsSuspended {
		log.Printf("Login attempt for suspended user '%s'", req.Username)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Account is suspended"})
		return
	}

	// Check for existing session and re-attach device
	if existingToken, found := session.FindSessionTokenByUsername(req.Username); found {
		log.Printf("User %s successfully re-authenticated. Attaching new device to existing session.", req.Username)
		existingSession, _ := session.GetSession(existingToken)
		newToken := uuid.New().String()
		session.AddSession(newToken, existingSession) // Add new token pointing to existing session

		c.JSON(http.StatusOK, LoginResponse{
			Success: true,
			Message: "Login successful, new device attached to session",
			Token:   newToken,
		})
		return
	}

	// First-time login for this session
	log.Printf("No existing session found for %s. Creating new session.", req.Username)

	userSession := session.NewUserSession(req.Username)
	userSession.Password = req.Password // Store password for potential SASL reconnect (or fetch from DB)
	userSession.SetUserID(user.ID)      // Set the UserID in the session

	// Load user's IRC networks from the database
	userNetworks, err := users.GetUserNetworks(user.ID)
	if err != nil {
		log.Printf("Error loading IRC networks for user %s: %v", req.Username, err)
		// Don't fail login, but user won't have networks automatically
	}

	// Attempt to connect to networks marked for auto-reconnect
	for _, netConfig := range userNetworks {
		userSession.Networks[netConfig.ID] = netConfig // Add to session map
		if netConfig.AutoReconnect {
			go func(nc *session.UserNetwork) {
				log.Printf("Attempting auto-reconnect for user %s, network %s", req.Username, nc.NetworkName)
				ircClient, connErr := irc.EstablishIRCConnection(userSession, nc, c.ClientIP()) // Pass actual client IP
				if connErr != nil {
					log.Printf("Auto-reconnect failed for user %s, network %s: %v", req.Username, nc.NetworkName, connErr)
					// Broadcast connection failure to the client
					userSession.Broadcast(events.EventTypeNetworkDisconnect, map[string]interface{}{
						"network_id":   nc.ID,
						"network_name": nc.NetworkName,
						"status":       "failed",
						"reason":       connErr.Error(),
					})
					return
				}
				nc.Mutex.Lock()
				nc.IRC = ircClient.Connection // Store the underlying ircevent connection
				nc.IsConnected = true
				nc.Mutex.Unlock()
				log.Printf("Auto-reconnect successful for user %s, network %s", req.Username, nc.NetworkName)
			}(netConfig)
		}
	}

	token := uuid.New().String()
	session.AddSession(token, userSession)

	c.JSON(http.StatusOK, LoginResponse{
		Success: true,
		Message: "Login successful",
		Token:   token,
	})
}

// ValidateSessionHandler remains largely the same.
func ValidateSessionHandler(c *gin.Context) {
	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	_, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "Session is valid"})
}