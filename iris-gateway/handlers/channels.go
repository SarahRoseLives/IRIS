package handlers

import (
	"fmt"
	"net/http"
	"reflect"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/session"
	// "iris-gateway/irc" // No longer needed here
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

	sess.Broadcast("channel_join", map[string]string{
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

	// Ensure the user's IRC connection exists
	if sess.IRC == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "User is not connected to IRC"})
		return
	}

	// MODIFIED: Use the user's IRC connection from their session to part the channel.
	sess.IRC.Part(req.Channel)

	// REMOVED: Do not modify session state here. The PART event callback in irc/connection.go
	// is the single source of truth and will handle removing the channel from the session
	// and broadcasting the update after the server confirms the action.
	//
	// sess.RemoveChannelFromSession(req.Channel)
	// irc.PartChannel(req.Channel) // <-- This was incorrect, it used the gateway bot.
	// sess.Broadcast("channel_part", ...) // <-- Also removed, handled by PART callback.


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

	type channelInfo struct {
		Name       string                  `json:"name"`
		Topic      string                  `json:"topic"` // Add this line to include the topic
		LastUpdate time.Time               `json:"last_update"`
		Members    []session.ChannelMember `json:"members"`
	}

	channels := make([]channelInfo, 0, len(sess.Channels))
	for _, ch := range sess.Channels {
		channels = append(channels, channelInfo{
			Name:       ch.Name,
			Topic:      ch.Topic, // Add this line to set the topic
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