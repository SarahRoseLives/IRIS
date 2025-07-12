package handlers

import (
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/irc" // Use the new irc/history module
	"iris-gateway/session"
)

// ChannelHistoryHandler now expects network ID as part of the path
// GET /api/history/:networkId/:channel
func ChannelHistoryHandler(c *gin.Context) {
	networkIDStr := c.Param("networkId")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
		return
	}

	channel := c.Param("channel")
	if channel == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Channel required"})
		return
	}

	limitStr := c.DefaultQuery("limit", "2500")
	limit, err := strconv.Atoi(limitStr)
	if err != nil || limit < 1 {
		limit = 2500
	}

	sinceParam := c.Query("since")
	var sinceTime *time.Time
	if sinceParam != "" {
		t, err := time.Parse(time.RFC3339, sinceParam)
		if err == nil {
			sinceTime = &t
		} else {
			log.Printf("[HISTORY] Invalid since param: %s", sinceParam)
		}
	}

	token, ok := getToken(c)
	if !ok {
		log.Printf("[HISTORY] Missing token for channel %s, network %d", channel, networkID)
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		log.Printf("[HISTORY] Invalid session for token")
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	// Verify user is in the channel on the specified network
	netConfig, found := sess.GetNetwork(networkID)
	if !found {
		log.Printf("[HISTORY] Network %d not found for user %s", networkID, sess.Username)
		c.JSON(http.StatusForbidden, gin.H{"success": false, "message": "Network not found"})
		return
	}

	netConfig.Mutex.RLock()
	_, inChannel := netConfig.Channels[strings.ToLower(channel)]
	netConfig.Mutex.RUnlock()

	if !inChannel {
		log.Printf("[HISTORY] User %s not in channel %s on network %d", sess.Username, channel, networkID)
		c.JSON(http.StatusForbidden, gin.H{"success": false, "message": "Not in channel"})
		return
	}

	history := irc.GetChannelHistory(networkID, channel, 0) // fetch all, filter manually below
	if history == nil || len(history) == 0 {
		log.Printf("[HISTORY] No history for network %d, channel %s", networkID, channel)
		c.JSON(http.StatusOK, gin.H{
			"success": true,
			"history": []map[string]interface{}{},
		})
		return
	}

	filtered := history
	if sinceTime != nil {
		filtered = make([]irc.Message, 0, len(history))
		for _, msg := range history {
			if msg.Timestamp.After(*sinceTime) {
				filtered = append(filtered, msg)
			}
		}
	}

	if len(filtered) > limit {
		filtered = filtered[len(filtered)-limit:]
	}

	messages := make([]map[string]interface{}, len(filtered))
	for i, msg := range filtered {
		messages[i] = map[string]interface{}{
			"network_id": msg.NetworkID, // Include network_id in response
			"channel":    msg.Channel,
			"sender":     msg.Sender,
			"text":       msg.Text,
			"timestamp":  msg.Timestamp.Format(time.RFC3339),
		}
	}

	log.Printf("[HISTORY] Returning %d messages for network %d, channel %s (since=%v)", len(messages), networkID, channel, sinceParam)
	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"history": messages,
	})
}