package handlers

import (
	"fmt"
	"net/http"
	"reflect" // Keep reflect if you use it elsewhere, otherwise it can be removed
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/events"
	"iris-gateway/session"
)

// getToken helper is in handlers/helpers.go (no change needed here)

// POST /api/channels/join (no changes needed for this specific issue)
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

	sess.AddChannelToSession(req.Channel) // session.AddChannelToSession handles ToLower internally

	sess.IRC.Join(req.Channel) // Send the join command to IRC with original case

	events.SendEvent("channel_join", map[string]string{
		"name": req.Channel, // Send original case to client for event display
		"user": sess.Username,
	})

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Join command sent for %s", req.Channel)})
}

// POST /api/channels/part (no changes needed for this specific issue)
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

	sess.RemoveChannelFromSession(req.Channel) // session.RemoveChannelFromSession handles ToLower internally

	sess.IRC.Part(req.Channel) // Send the part command to IRC with original case

	events.SendEvent("channel_part", map[string]string{
		"name": req.Channel, // Send original case to client for event display
		"user": sess.Username,
	})

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Part command sent for %s", req.Channel)})
}

// GET /api/channels (no changes needed for this specific issue)
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

	type channelInfo struct {
		Name       string    `json:"name"`
		LastUpdate time.Time `json:"last_update"`
		Members    []string  `json:"members"`
	}

	channels := make([]channelInfo, 0, len(sess.Channels))
	for _, ch := range sess.Channels {
		channels = append(channels, channelInfo{
			Name:       ch.Name,
			LastUpdate: ch.LastUpdate,
			Members:    ch.Members,
		})
	}
	sess.Mutex.RUnlock()

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"channels": channels,
	})
}

// GET /api/channels/:channelName/messages
// This handler now correctly returns the message history for the specified channel.
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

    // Normalize channel name for lookup
    normalizedChannelName := strings.ToLower(channelName)

    sess.Mutex.RLock()
    channelState, exists := sess.Channels[normalizedChannelName]
    sess.Mutex.RUnlock()

    if !exists {
        c.JSON(http.StatusNotFound, gin.H{"success": false, "message": fmt.Sprintf("Channel '%s' not found", channelName)})
        return
    }

    // Get messages from channel state
    messages := channelState.GetMessages()

    // --- ADD THESE DEBUG PRINTS ---
    fmt.Printf("[GetChannelMessagesHandler] Channel '%s' has %d messages.\n", channelName, len(messages))
    // Print a few messages to ensure content is there
    for i, msg := range messages {
        if i < 5 { // Print first 5 messages
            fmt.Printf("  Message %d: From='%s', Content='%s', Time='%s'\n", i, msg.From, msg.Content, msg.Time.Format(time.RFC3339))
        } else if i == 5 {
            fmt.Printf("  ... (and %d more messages)\n", len(messages) - 5)
        }
    }
    // --- END ADDITIONS ---

    // Convert to format expected by Flutter client
    var responseMessages []map[string]interface{}
    for _, msg := range messages {
        responseMessages = append(responseMessages, map[string]interface{}{
            "from":    msg.From,
            "content": msg.Content,
            "time":    msg.Time.Format(time.RFC3339),
        })
    }

    // --- ADD THIS DEBUG PRINT FOR THE FINAL PAYLOAD ---
    fmt.Printf("[GetChannelMessagesHandler] Sending JSON response for '%s': success=true, messages_count=%d\n", channelName, len(responseMessages))
    // --- END ADDITION ---

    c.JSON(http.StatusOK, gin.H{
        "success":  true,
        "messages": responseMessages, // Messages at root level
    })
}