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

	sess.AddChannelToSession(req.Channel)

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

	sess.RemoveChannelFromSession(req.Channel)

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

	sess.Mutex.RLock()
	fmt.Printf("[/api/channels] Token=%s Channels=%d Keys=%v (session_ptr: %p)\n",
		token,
		len(sess.Channels),
		reflect.ValueOf(sess.Channels).MapKeys(),
		sess,
	)

	// MODIFIED: The channelInfo struct to include the new member format.
	type channelInfo struct {
		Name       string                  `json:"name"`
		LastUpdate time.Time               `json:"last_update"`
		Members    []session.ChannelMember `json:"members"`
	}

	channels := make([]channelInfo, 0, len(sess.Channels))
	for _, ch := range sess.Channels {
		channels = append(channels, channelInfo{
			Name:       ch.Name,
			LastUpdate: ch.LastUpdate,
			Members:    ch.Members, // This now contains Nick and Prefix for each member
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

	normalizedChannelName := strings.ToLower(channelName)

	sess.Mutex.RLock()
	channelState, exists := sess.Channels[normalizedChannelName]
	sess.Mutex.RUnlock()

	if !exists {
		c.JSON(http.StatusNotFound, gin.H{"success": false, "message": fmt.Sprintf("Channel '%s' not found", channelName)})
		return
	}

	messages := channelState.GetMessages()

	fmt.Printf("[GetChannelMessagesHandler] Channel '%s' has %d messages.\n", channelName, len(messages))
	for i, msg := range messages {
		if i < 5 {
			fmt.Printf("  Message %d: From='%s', Content='%s', Time='%s'\n", i, msg.From, msg.Content, msg.Time.Format(time.RFC3339))
		} else if i == 5 {
			fmt.Printf("  ... (and %d more messages)\n", len(messages)-5)
		}
	}

	var responseMessages []map[string]interface{}
	for _, msg := range messages {
		responseMessages = append(responseMessages, map[string]interface{}{
			"from":    msg.From,
			"content": msg.Content,
			"time":    msg.Time.Format(time.RFC3339),
		})
	}

	fmt.Printf("[GetChannelMessagesHandler] Sending JSON response for '%s': success=true, messages_count=%d\n", channelName, len(responseMessages))

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"messages": responseMessages,
	})
}