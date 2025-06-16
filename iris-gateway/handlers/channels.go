package handlers

import (
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/events"
	"iris-gateway/session"
)

// Helper to extract Bearer token from Authorization header
func getToken(c *gin.Context) (string, bool) {
	auth := c.GetHeader("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		return strings.TrimPrefix(auth, "Bearer "), true
	}
	return "", false
}

// POST /api/channels/join
func JoinChannelHandler(c *gin.Context) {
	type request struct {
		Channel string `json:"channel"`
	}
	var req request
	if err := c.ShouldBindJSON(&req); err != nil || req.Channel == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Channel required"})
		return
	}

	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	sess.IRC.Join(req.Channel)

	events.SendEvent("channel_join", map[string]string{
		"name": req.Channel,
		"user": sess.Username,
	})

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Join command sent for %s", req.Channel)})
}

// POST /api/channels/part
func PartChannelHandler(c *gin.Context) {
	type request struct {
		Channel string `json:"channel"`
	}
	var req request
	if err := c.ShouldBindJSON(&req); err != nil || req.Channel == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Channel required"})
		return
	}

	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	sess.IRC.Part(req.Channel)

	events.SendEvent("channel_part", map[string]string{
		"name": req.Channel,
		"user": sess.Username,
	})

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Part command sent for %s", req.Channel)})
}

// GET /api/channels
func ListChannelsHandler(c *gin.Context) {
	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	fmt.Printf("[/api/channels] Token=%s Channels=%d Keys=%v\n",
		token,
		len(sess.Channels),
		reflect.ValueOf(sess.Channels).MapKeys(),
	)

	type channelInfo struct {
		Name       string    `json:"name"`
		LastUpdate time.Time `json:"last_update"`
	}

	sess.Mutex.RLock()
	channels := make([]channelInfo, 0, len(sess.Channels))
	for name, ch := range sess.Channels {
		channels = append(channels, channelInfo{
			Name:       name,
			LastUpdate: ch.LastUpdate,
		})
	}
	sess.Mutex.RUnlock()

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"channels": channels,
	})
}

// GET /api/channels/:channelName/messages
func GetChannelMessagesHandler(c *gin.Context) {
	channelName := c.Param("channelName")
	if channelName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Channel name required"})
		return
	}

	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	sess.Mutex.RLock()
	channelState, exists := sess.Channels[channelName]

	// --- NEW: Ensure messages is always a non-nil slice ---
	messages := make([]session.Message, 0) // Initialize as an empty slice
	if exists && channelState.Messages != nil {
		// Only copy if the channel exists AND its messages slice is not nil
		messages = make([]session.Message, len(channelState.Messages))
		copy(messages, channelState.Messages)
	}
	sess.Mutex.RUnlock()
	// --- END NEW ---

	if !exists { // Check existence AFTER unlocking, if you're not using the messages slice.
		// For this logic, it's safer to have the messages var before this check.
		c.JSON(http.StatusNotFound, gin.H{"success": false, "message": "Channel not found in session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"channel":  channelName,
		"messages": messages, // This will now always be an array (even if empty), never null
	})
}