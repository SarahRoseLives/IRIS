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

	// Get limit from query param, default to 5000
	limitStr := c.DefaultQuery("limit", "5000")
	limit, err := strconv.Atoi(limitStr)
	if err != nil || limit < 1 {
		limit = 5000
	}

	// Parse optional "since" query parameter
	sinceParam := c.Query("since")
	var sinceTime *time.Time
	if sinceParam != "" {
		t, err := time.Parse(time.RFC3339, sinceParam)
		if err == nil {
			sinceTime = &t
		} else {
			log.Printf("[HISTORY] Invalid since param: %s", sinceParam)
			// Silently ignore invalid "since" value, return all (up to limit)
		}
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

	history := irc.GetChannelHistory(channel, 0) // fetch all, filter manually below
	if history == nil || len(history) == 0 {
		log.Printf("[HISTORY] No history for channel %s", channel)
		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"history": []map[string]interface{}{},
		})
		return
	}

	// Filter by since, if present
	filtered := history
	if sinceTime != nil {
		filtered = make([]irc.Message, 0, len(history))
		for _, msg := range history {
			if msg.Timestamp.After(*sinceTime) {
				filtered = append(filtered, msg)
			}
		}
	}

	// Apply limit: return up to limit most recent messages
	if len(filtered) > limit {
		filtered = filtered[len(filtered)-limit:]
	}

	// Convert messages to API response format
	messages := make([]map[string]interface{}, len(filtered))
	for i, msg := range filtered {
		messages[i] = map[string]interface{}{
			"channel":   msg.Channel,
			"sender":    msg.Sender,
			"text":      msg.Text,
			"timestamp": msg.Timestamp.Format(time.RFC3339),
		}
	}

	log.Printf("[HISTORY] Returning %d messages for channel %s (since=%v)", len(messages), channel, sinceParam)
	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"history": messages,
	})
}