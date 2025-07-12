package handlers

import (
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/session"
)

type ChannelRequest struct {
	NetworkID int    `json:"network_id"`
	Channel   string `json:"channel"`
}

// POST /api/channels/join
func JoinChannelHandler(c *gin.Context) {
	var req ChannelRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.Channel == "" || req.NetworkID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Network ID and Channel required"})
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

	netConfig, found := sess.GetNetwork(req.NetworkID)
	if !found || netConfig.IRC == nil || !netConfig.IsConnected {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "message": "IRC network not connected or not found"})
		return
	}

	// Add channel to the session's network configuration state immediately
	netConfig.AddChannelToNetwork(req.Channel)

	// Send JOIN command to the specific IRC connection
	netConfig.IRC.Join(req.Channel)

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Join command sent for %s on network %s", req.Channel, netConfig.NetworkName)})
}

// POST /api/channels/part
func PartChannelHandler(c *gin.Context) {
	var req ChannelRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.Channel == "" || req.NetworkID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Network ID and Channel required"})
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

	netConfig, found := sess.GetNetwork(req.NetworkID)
	if !found || netConfig.IRC == nil || !netConfig.IsConnected {
		c.JSON(http.StatusServiceUnavailable, gin.H{"success": false, "message": "IRC network not connected or not found"})
		return
	}

	netConfig.IRC.Part(req.Channel)

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Part command sent for %s on network %s", req.Channel, netConfig.NetworkName)})
}

// GET /api/channels
// This will now return channels for ALL connected networks for the user.
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

	type channelInfo struct {
		NetworkID   int                     `json:"network_id"` // New field
		NetworkName string                  `json:"network_name"` // New field
		Name        string                  `json:"name"`
		Topic       string                  `json:"topic"`
		LastUpdate  time.Time               `json:"last_update"`
		Members     []session.ChannelMember `json:"members"`
	}

	allChannels := make([]channelInfo, 0)

	sess.Mutex.RLock()
	defer sess.Mutex.RUnlock()

	for _, netConfig := range sess.Networks {
		netConfig.Mutex.RLock() // Lock the specific network config
		for _, ch := range netConfig.Channels {
			ch.Mutex.RLock() // Lock the specific channel state
			allChannels = append(allChannels, channelInfo{
				NetworkID:   netConfig.ID,
				NetworkName: netConfig.NetworkName,
				Name:        ch.Name,
				Topic:       ch.Topic,
				LastUpdate:  ch.LastUpdate,
				Members:     ch.Members,
			})
			ch.Mutex.RUnlock() // Unlock channel state
		}
		netConfig.Mutex.RUnlock() // Unlock network config
	}

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"channels": allChannels,
	})
}