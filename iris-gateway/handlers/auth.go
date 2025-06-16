package handlers

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net" // New import for net package
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	ircevent "github.com/thoj/go-ircevent"
	"iris-gateway/config"
	"iris-gateway/irc"
	"iris-gateway/session"
)

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// LoginResponse will be used for LoginHandler
type LoginResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	Token   string `json:"token,omitempty"` // Add token to the response
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

	// Check if there is already a session for this username
	existingToken, found := session.FindSessionTokenByUsername(req.Username)
	if found {
		c.JSON(http.StatusOK, LoginResponse{
			Success: true,
			Message: "Already logged in",
			Token:   existingToken,
		})
		return
	}

	// Authenticate with Ergo
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
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Gateway error"})
		return
	}
	defer resp.Body.Close()

	respData, _ := io.ReadAll(resp.Body)
	var result map[string]interface{}
	_ = json.Unmarshal(respData, &result)

	if resp.StatusCode != 200 || result["success"] != true {
		msg, _ := result["message"].(string)
		if msg == "" {
			msg = "Login failed"
		}
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": msg})
		return
	}

	// Extract the client's IP address
	clientIP, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		clientIP = c.Request.RemoteAddr // Fallback if SplitHostPort fails (e.g., no port)
	}

	// Connect to IRC
	// Pass the clientIP to the AuthenticateWithNickServ function
	client, err := irc.AuthenticateWithNickServ(req.Username, req.Password, clientIP)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "IRC login failed: " + err.Error()})
		return
	}

	fmt.Printf("[SESSION] IRC pointer for user %s: %p\n", req.Username, client)

	userSession := &session.UserSession{
		Username: req.Username,
		IRC:      client,
		Channels: make(map[string]*session.ChannelState),
	}

	// Register callbacks BEFORE any join
	client.AddCallback("JOIN", func(e *ircevent.Event) {
		fmt.Printf("[IRC] JOIN callback fired on IRC pointer: %p\n", e.Connection)
		fmt.Printf("[IRC] Raw JOIN Event: %+v\n", e)

		if !strings.EqualFold(e.Nick, userSession.Username) {
			return
		}

		var channel string
		if len(e.Arguments) > 0 {
			channel = e.Arguments[len(e.Arguments)-1]
		} else {
			channel = e.Message()
		}

		fmt.Printf("[IRC] User %s JOINED %s\n", e.Nick, channel)

		userSession.Mutex.Lock()
		if _, exists := userSession.Channels[channel]; !exists {
			userSession.Channels[channel] = &session.ChannelState{
				Name:       channel,
				Members:    []string{userSession.Username},
				Messages:   []session.Message{},
				LastUpdate: time.Now(),
			}
		} else {
			userSession.Channels[channel].LastUpdate = time.Now()
		}
		userSession.Mutex.Unlock()
	})

	client.AddCallback("PART", func(e *ircevent.Event) {
		fmt.Printf("[IRC] PART callback fired on IRC pointer: %p\n", e.Connection)

		if strings.EqualFold(e.Nick, userSession.Username) && len(e.Arguments) > 0 {
			channel := e.Arguments[0]
			userSession.Mutex.Lock()
			delete(userSession.Channels, channel)
			userSession.Mutex.Unlock()
			fmt.Printf("[IRC] User %s PARTED %s\n", e.Nick, channel)
		}
	})

	// Optional: Join fallback default (can be removed if auto-joins are guaranteed)
	client.Join("#welcome")

	token := uuid.New().String()
	session.AddSession(token, userSession)

	fmt.Printf("[SESSION] Created for %s with token %s\n", req.Username, token)

	c.JSON(http.StatusOK, LoginResponse{
		Success: true,
		Message: "Login successful",
		Token:   token,
	})
}