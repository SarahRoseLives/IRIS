package handlers

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"iris-gateway/config"
	"iris-gateway/irc"
	"iris-gateway/session"
)

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type LoginResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	Token   string `json:"token,omitempty"`
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

	// --- Step 1: Authenticate the user's credentials with Ergo ---
	body := map[string]string{
		"accountName": req.Username,
		"passphrase":  req.Password,
	}
	payload, _ := json.Marshal(body)

	httpReq, _ := http.NewRequest("POST", config.Cfg.ErgoAPIURL, bytes.NewReader(payload))
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Authorization", "Bearer "+config.Cfg.BearerToken)

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		log.Printf("Ergo authentication request failed: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Gateway error during authentication"})
		return
	}
	defer resp.Body.Close()

	respData, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("Failed to read Ergo response body: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to read authentication response"})
		return
	}

	var result map[string]interface{}
	if err := json.Unmarshal(respData, &result); err != nil {
		log.Printf("Failed to unmarshal Ergo response: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to parse authentication response"})
		return
	}

	if resp.StatusCode != http.StatusOK || result["success"] != true {
		msg, _ := result["message"].(string)
		if msg == "" {
			msg = "Invalid username or password"
		}
		log.Printf("Ergo authentication failed for user '%s': status %d, message: %s", req.Username, resp.StatusCode, msg)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": msg})
		return
	}

	// --- Step 2: Handle Multi-Device Login ---
	// After successful password validation, check if the user already has a running session.
	if existingToken, found := session.FindSessionTokenByUsername(req.Username); found {
		log.Printf("User %s successfully re-authenticated. Attaching new device to existing session.", req.Username)

		// Get the single, shared session object.
		existingSession, _ := session.GetSession(existingToken)

		// Generate a new, unique token for this new device.
		newToken := uuid.New().String()

		// ** THIS IS THE FIX **
		// We simply add the new token and point it to the existing session.
		// We DO NOT unmap the old token, allowing multiple devices to be active.
		session.AddSession(newToken, existingSession)

		// Return the new token to the new device. It will use this to open its WebSocket
		// connection, which will be added to the shared UserSession.
		c.JSON(http.StatusOK, LoginResponse{
			Success: true,
			Message: "Login successful, new device attached to session",
			Token:   newToken,
		})
		return // IMPORTANT: End the handler here.
	}

	// --- Step 3: Handle First-Time Login ---
	// This code will only run if no existing session was found for the user.
	log.Printf("No existing session found for %s. Creating new IRC connection and session.", req.Username)

	clientIP, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		clientIP = c.Request.RemoteAddr
		log.Printf("Could not split host port for RemoteAddr '%s', using full address as IP: %v", c.Request.RemoteAddr, err)
	}

	// Create the core session object and the IRC connection.
	userSession := session.NewUserSession(req.Username)
	userSession.Password = req.Password

	client, err := irc.AuthenticateWithNickServ(req.Username, req.Password, clientIP, userSession)
	if err != nil {
		log.Printf("IRC login failed for user %s: %v", req.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "IRC login failed: " + err.Error()})
		return
	}

	userSession.IRC = client

	// Generate the first token for the first device.
	token := uuid.New().String()
	session.AddSession(token, userSession)

	// Fetch any offline messages.
	go func(username string, userSession *session.UserSession) {
		time.Sleep(2 * time.Second)
		messages := irc.GetAndClearOfflineMessages(username)
		for _, msg := range messages {
			userSession.Broadcast("message", map[string]interface{}{
				"channel_name": "@" + msg.Sender,
				"sender":       msg.Sender,
				"text":         msg.Text,
				"time":         msg.Timestamp.Format(time.RFC3339),
			})
		}
	}(req.Username, userSession)

	c.JSON(http.StatusOK, LoginResponse{
		Success: true,
		Message: "Login successful",
		Token:   token,
	})
}

// ValidateSessionHandler checks if a session token is still valid.
func ValidateSessionHandler(c *gin.Context) {
	token, ok := getToken(c) // Use your existing helper to get the token
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	// Check if the session exists in our map
	_, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	// If we get here, the session is valid
	c.JSON(http.StatusOK, gin.H{"success": true, "message": "Session is valid"})
}