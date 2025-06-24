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

	existingToken, found := session.FindSessionTokenByUsername(req.Username)
	if found {
		c.JSON(http.StatusOK, LoginResponse{
			Success: true,
			Message: "Already logged in",
			Token:   existingToken,
		})
		return
	}

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
			msg = "Login failed"
		}
		log.Printf("Ergo authentication failed: status %d, message: %s", resp.StatusCode, msg)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": msg})
		return
	}

	clientIP, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		clientIP = c.Request.RemoteAddr
		log.Printf("Could not split host port for RemoteAddr '%s', using full address as IP: %v", c.Request.RemoteAddr, err)
	}

	// MODIFIED: Use the new constructor function instead of a struct literal.
	userSession := session.NewUserSession(req.Username)

	// MODIFIED: Pass the entire userSession object, which also satisfies the ChannelStateUpdater interface.
	client, err := irc.AuthenticateWithNickServ(req.Username, req.Password, clientIP, userSession)
	if err != nil {
		log.Printf("IRC login failed for user %s: %v", req.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "IRC login failed: " + err.Error()})
		return
	}

	log.Printf("[SESSION] IRC pointer for user %s: %p", req.Username, client)
	userSession.IRC = client

	defaultChannel := "#welcome"
	client.Join(defaultChannel)
	userSession.AddChannelToSession(defaultChannel)
	log.Printf("[LoginHandler] Immediately added %s to session for user %s", defaultChannel, userSession.Username)

	token := uuid.New().String()
	session.AddSession(token, userSession)

	log.Printf("[SESSION] Created for %s with token %s", req.Username, token)

	// --- OFFLINE DM DELIVERY ---
	// After successful login, deliver any queued messages for this user.
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
	// --- END OFFLINE DM DELIVERY ---

	c.JSON(http.StatusOK, LoginResponse{
		Success: true,
		Message: "Login successful",
		Token:   token,
	})
}