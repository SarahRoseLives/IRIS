package handlers

import (
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/irc"
	"iris-gateway/session"
)

func ChannelHistoryHandler(c *gin.Context) {
	channel := c.Param("channel")
	if channel == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Channel required"})
		return
	}

	// Get limit from query param, default to 100
	limitStr := c.DefaultQuery("limit", "100")
	limit, err := strconv.Atoi(limitStr)
	if err != nil || limit < 1 {
		limit = 100
	}

	token, ok := getToken(c)
	if !ok {
		log.Printf("[HISTORY] Missing token for channel %s", channel)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		log.Printf("[HISTORY] Invalid session for token")
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	// Verify user is in the channel
	sess.Mutex.RLock()
	_, inChannel := sess.Channels[strings.ToLower(channel)]
	sess.Mutex.RUnlock()

	if !inChannel {
		log.Printf("[HISTORY] User not in channel %s", channel)
		c.JSON(http.StatusForbidden, gin.H{"success": false, "message": "Not in channel"})
		return
	}

	history := irc.GetChannelHistory(channel, limit)
	if history == nil || len(history) == 0 {
		log.Printf("[HISTORY] No history for channel %s", channel)
		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"history": []map[string]interface{}{},
		})
		return
	}

	// Convert messages to API response format
	messages := make([]map[string]interface{}, len(history))
	for i, msg := range history {
		messages[i] = map[string]interface{}{
			"channel":   msg.Channel,
			"sender":    msg.Sender,
			"text":      msg.Text,
			"timestamp": msg.Timestamp.Format(time.RFC3339),
		}
	}

	log.Printf("[HISTORY] Returning %d messages for channel %s", len(messages), channel)
	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"history": messages,
	})
}