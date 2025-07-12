package handlers

import (
	"fmt"
	"log"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"iris-gateway/session"
	"iris-gateway/users"
	"iris-gateway/irc"
	"iris-gateway/events"
)

// AddNetworkRequest defines the structure for adding a new IRC network
type AddNetworkRequest struct {
	NetworkName     string   `json:"network_name" binding:"required"`
	Hostname        string   `json:"hostname" binding:"required"`
	Port            int      `json:"port" binding:"required"`
	UseSSL          bool     `json:"use_ssl"`
	ServerPassword  string   `json:"server_password"`
	AutoReconnect   bool     `json:"auto_reconnect"`
	Modules         []string `json:"modules"`
	PerformCommands []string `json:"perform_commands"`
	InitialChannels []string `json:"initial_channels"`
	Nickname        string   `json:"nickname" binding:"required"`
	AltNickname     string   `json:"alt_nickname"`
	Ident           string   `json:"ident"`
	Realname        string   `json:"realname"`
	QuitMessage     string   `json:"quit_message"`
}

// AddNetworkHandler handles adding a new IRC network configuration for a user.
// POST /api/irc/networks
func AddNetworkHandler(c *gin.Context) {
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

	var req AddNetworkRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"success": false,
			"message": fmt.Sprintf("Invalid request: %v", err),
		})
		return
	}

	// Validate required fields
	if req.NetworkName == "" || req.Hostname == "" || req.Nickname == "" {
		c.JSON(http.StatusBadRequest, gin.H{
			"success": false,
			"message": "Network name, hostname and nickname are required",
		})
		return
	}

	// Create a UserNetwork object from the request
	netConfig := &session.UserNetwork{
		UserID:          sess.UserID, // Set the UserID from the session
		NetworkName:     req.NetworkName,
		Hostname:        req.Hostname,
		Port:            req.Port,
		UseSSL:          req.UseSSL,
		ServerPassword:  req.ServerPassword,
		AutoReconnect:   req.AutoReconnect,
		Modules:         req.Modules,
		PerformCommands: req.PerformCommands,
		InitialChannels: req.InitialChannels,
		Nickname:        req.Nickname,
		AltNickname:     req.AltNickname,
		Ident:           req.Ident,
		Realname:        req.Realname,
		QuitMessage:     req.QuitMessage,
		IsConnected:     false, // Initially not connected
		Channels:        make(map[string]*session.ChannelState),
	}

	networkID, err := users.AddUserNetwork(sess.UserID, netConfig)
	if err != nil {
		log.Printf("Failed to add network for user %s: %v", sess.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{
			"success": false,
			"message": "Failed to add network configuration",
		})
		return
	}

	netConfig.ID = networkID // Update the ID from the database
	sess.Mutex.Lock()
	sess.Networks[networkID] = netConfig // Add to live session
	sess.Mutex.Unlock()

	log.Printf("User %s added new network: %s (ID: %d)", sess.Username, req.NetworkName, networkID)

	// Optionally attempt to connect immediately if auto-reconnect is true or explicitly requested
	if req.AutoReconnect {
		go func() {
			log.Printf("Attempting immediate connect for new network %s (ID: %d) for user %s", req.NetworkName, networkID, sess.Username)
			ircClient, connErr := irc.EstablishIRCConnection(sess, netConfig, c.ClientIP())
			if connErr != nil {
				log.Printf("Initial connect failed for new network %s (ID: %d): %v", req.NetworkName, networkID, connErr)
				sess.Broadcast(events.EventTypeNetworkDisconnect, map[string]interface{}{
					"network_id":   netConfig.ID,
					"network_name": netConfig.NetworkName,
					"status":       "failed",
					"reason":       connErr.Error(),
				})
				// Don't remove from session.Networks even on failure, keep the config.
				// The `IsConnected` flag will reflect the status.
				return
			}
			netConfig.Mutex.Lock()
			netConfig.IRC = ircClient.Connection
			netConfig.IsConnected = true
			netConfig.Mutex.Unlock()
			log.Printf("Successfully connected new network %s (ID: %d) for user %s", req.NetworkName, networkID, sess.Username)
		}()
	}

	c.JSON(http.StatusCreated, gin.H{
		"success": true,
		"message": "Network added successfully",
		"network": gin.H{
			"id":             networkID,
			"network_name":   netConfig.NetworkName,
			"hostname":       netConfig.Hostname,
			"port":           netConfig.Port,
			"use_ssl":        netConfig.UseSSL,
			"auto_reconnect": netConfig.AutoReconnect,
			"is_connected":   false,
		},
	})
}

// ListNetworksHandler lists all IRC network configurations for a user.
// GET /api/irc/networks
func ListNetworksHandler(c *gin.Context) {
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

	// Get networks from database
	userNetworks, err := users.GetUserNetworks(sess.UserID)
	if err != nil {
		log.Printf("Failed to list networks for user %s: %v", sess.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{
			"success": false,
			"message": "Failed to retrieve networks",
		})
		return
	}

	// Convert to response format
	networks := make([]map[string]interface{}, len(userNetworks))
	for i, net := range userNetworks {
		networks[i] = map[string]interface{}{
			"id":               net.ID,
			"network_name":     net.NetworkName,
			"hostname":         net.Hostname,
			"port":             net.Port,
			"use_ssl":          net.UseSSL,
			"auto_reconnect":   net.AutoReconnect,
			"nickname":         net.Nickname,
			"alt_nickname":     net.AltNickname,
			"ident":            net.Ident,
			"realname":         net.Realname,
			"quit_message":     net.QuitMessage,
			"is_connected":     false, // Default to false, will update from session
		}

		// Check if network is connected in session
		if sessNet, exists := sess.Networks[net.ID]; exists && sessNet.IsConnected {
			networks[i]["is_connected"] = true
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"networks": networks,
	})
}

// UpdateNetworkHandler handles updating an existing IRC network configuration.
// PUT /api/irc/networks/:id
func UpdateNetworkHandler(c *gin.Context) {
	networkIDStr := c.Param("id")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
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

	var req AddNetworkRequest // Re-use the same request struct
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": fmt.Sprintf("Invalid request: %v", err)})
		return
	}

	// Get the existing network config from the session (live state)
	existingNetConfig, existsInSession := sess.GetNetwork(networkID)
	if !existsInSession {
		// If not in session, try loading from DB. If still not found, it's an error.
		dbNetworks, dbErr := users.GetUserNetworks(sess.UserID)
		if dbErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to check existing network"})
			return
		}
		foundInDB := false
		for _, net := range dbNetworks {
			if net.ID == networkID {
				existingNetConfig = net
				existsInSession = true // Found in DB, will be updated.
				foundInDB = true
				break
			}
		}
		if !foundInDB {
			c.JSON(http.StatusNotFound, gin.H{"success": false, "message": "Network configuration not found"})
			return
		}
	}

	// Update the existing network config with new values from request
	existingNetConfig.NetworkName = req.NetworkName
	existingNetConfig.Hostname = req.Hostname
	existingNetConfig.Port = req.Port
	existingNetConfig.UseSSL = req.UseSSL
	existingNetConfig.ServerPassword = req.ServerPassword
	existingNetConfig.AutoReconnect = req.AutoReconnect
	existingNetConfig.Modules = req.Modules
	existingNetConfig.PerformCommands = req.PerformCommands
	existingNetConfig.InitialChannels = req.InitialChannels
	existingNetConfig.Nickname = req.Nickname
	existingNetConfig.AltNickname = req.AltNickname
	existingNetConfig.Ident = req.Ident
	existingNetConfig.Realname = req.Realname
	existingNetConfig.QuitMessage = req.QuitMessage

	err = users.UpdateUserNetwork(sess.UserID, existingNetConfig)
	if err != nil {
		log.Printf("Failed to update network %d for user %s: %v", networkID, sess.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to update network"})
		return
	}

	log.Printf("User %s updated network: %s (ID: %d)", sess.Username, req.NetworkName, networkID)

	// If the network was connected, disconnect and re-connect to apply new settings
	if existingNetConfig.IsConnected {
		log.Printf("Network %s (ID: %d) was connected, attempting to re-connect to apply changes.", req.NetworkName, networkID)
		if existingNetConfig.IRC != nil {
			existingNetConfig.IRC.Quit() // This will trigger the DISCONNECT handler and eventual reconnect logic
		}
		// Force immediate reconnect (instead of waiting for AutoReconnect logic)
		go func() {
			ReconnectNetwork(sess, networkID, c.ClientIP()) // Pass sess and clientIP
		}()
	}


	c.JSON(http.StatusOK, gin.H{"success": true, "message": "Network updated successfully"})
}

// DeleteNetworkHandler handles deleting an IRC network configuration.
// DELETE /api/irc/networks/:id
func DeleteNetworkHandler(c *gin.Context) {
	networkIDStr := c.Param("id")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
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

	// Disconnect IRC if connected before deleting
	netConfig, existsInSession := sess.GetNetwork(networkID)
	if existsInSession && netConfig.IRC != nil && netConfig.IsConnected {
		log.Printf("User %s: Disconnecting IRC for network %s (ID: %d) before deletion.", sess.Username, netConfig.NetworkName, networkID)
		netConfig.IRC.Quit()
		// The DISCONNECT handler will clean up `netConfig.IRC` and `IsConnected`
	}

	err = users.DeleteUserNetwork(sess.UserID, networkID)
	if err != nil {
		log.Printf("Failed to delete network %d for user %s: %v", networkID, sess.Username, err)
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to delete network"})
		return
	}

	sess.Mutex.Lock()
	delete(sess.Networks, networkID) // Remove from live session
	sess.Mutex.Unlock()

	log.Printf("User %s deleted network (ID: %d)", sess.Username, networkID)
	c.JSON(http.StatusOK, gin.H{"success": true, "message": "Network deleted successfully"})
}

// ConnectNetworkHandler handles manually connecting to an IRC network.
// POST /api/irc/networks/:id/connect
func ConnectNetworkHandler(c *gin.Context) {
	networkIDStr := c.Param("id")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
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

	netConfig, found := sess.GetNetwork(networkID)
	if !found {
		// If not in session, try loading from DB.
		dbNetworks, dbErr := users.GetUserNetworks(sess.UserID)
		if dbErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to retrieve network from database"})
			return
		}
		for _, net := range dbNetworks {
			if net.ID == networkID {
				netConfig = net
				sess.Mutex.Lock()
				sess.Networks[networkID] = netConfig // Add to live session
				sess.Mutex.Unlock()
				found = true
				break
			}
		}
		if !found {
			c.JSON(http.StatusNotFound, gin.H{"success": false, "message": "Network configuration not found"})
			return
		}
	}

	if netConfig.IsConnected {
		c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Network %s is already connected.", netConfig.NetworkName)})
		return
	}

	log.Printf("User %s: Attempting manual connect for network %s (ID: %d)", sess.Username, netConfig.NetworkName, networkID)
	go func() {
		ircClient, connErr := irc.EstablishIRCConnection(sess, netConfig, c.ClientIP())
		if connErr != nil {
			log.Printf("Manual connect failed for network %s (ID: %d): %v", netConfig.NetworkName, networkID, connErr)
			sess.Broadcast(events.EventTypeNetworkDisconnect, map[string]interface{}{
				"network_id":   netConfig.ID,
				"network_name": netConfig.NetworkName,
				"status":       "failed",
				"reason":       connErr.Error(),
			})
			return
		}
		netConfig.Mutex.Lock()
		netConfig.IRC = ircClient.Connection
		netConfig.IsConnected = true
		netConfig.Mutex.Unlock()
		log.Printf("Successfully connected network %s (ID: %d) for user %s", netConfig.NetworkName, networkID, sess.Username)
	}()

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Attempting to connect to network %s.", netConfig.NetworkName)})
}

// DisconnectNetworkHandler handles manually disconnecting from an IRC network.
// POST /api/irc/networks/:id/disconnect
func DisconnectNetworkHandler(c *gin.Context) {
	networkIDStr := c.Param("id")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
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

	netConfig, found := sess.GetNetwork(networkID)
	if !found {
		c.JSON(http.StatusNotFound, gin.H{"success": false, "message": "Network configuration not found in session"})
		return
	}

	if netConfig.IRC == nil || !netConfig.IsConnected {
		c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Network %s is already disconnected.", netConfig.NetworkName)})
		return
	}

	log.Printf("User %s: Disconnecting from network %s (ID: %d)", sess.Username, netConfig.NetworkName, networkID)
	netConfig.IRC.Quit() // This will trigger the DISCONNECT handler in irc_client.go

	c.JSON(http.StatusOK, gin.H{"success": true, "message": fmt.Sprintf("Disconnect command sent for network %s.", netConfig.NetworkName)})
}

// ReconnectNetwork is a helper function to reconnect a specific network for a user session.
// It's used by UpdateNetworkHandler and can be called by the irc.irc_client.go DISCONNECT handler.
func ReconnectNetwork(s *session.UserSession, networkID int, clientIP string) {
    s.Mutex.RLock()
    netConfig, found := s.Networks[networkID]
    s.Mutex.RUnlock()

    if !found {
        log.Printf("Attempted reconnect for unknown network ID %d for user %s", networkID, s.Username)
        return
    }

    log.Printf("User %s: Initiating reconnect for network %s (ID: %d)", s.Username, netConfig.NetworkName, networkID)
    ircClient, connErr := irc.EstablishIRCConnection(s, netConfig, clientIP)
    if connErr != nil {
        log.Printf("Reconnect failed for network %s (ID: %d): %v", netConfig.NetworkName, networkID, connErr)
        s.Broadcast(events.EventTypeNetworkDisconnect, map[string]interface{}{
            "network_id":   netConfig.ID,
            "network_name": netConfig.NetworkName,
            "status":       "failed",
            "reason":       connErr.Error(),
        })
        return
    }
    netConfig.Mutex.Lock()
    netConfig.IRC = ircClient.Connection
    netConfig.IsConnected = true
    // Clear existing channels as we will get new JOINs/NAMES on reconnect
    netConfig.Channels = make(map[string]*session.ChannelState)
    netConfig.Mutex.Unlock()
    log.Printf("Reconnect successful for network %s (ID: %d) for user %s", netConfig.NetworkName, networkID, s.Username)
}

// GetNetworkDetailsHandler fetches a single IRC network's details by ID.
// GET /api/irc/networks/:id
func GetNetworkDetailsHandler(c *gin.Context) {
	networkIDStr := c.Param("id")
	networkID, err := strconv.Atoi(networkIDStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid network ID"})
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

	// Fetch network from the database for the specific user and network ID
	netConfig, err := users.GetSingleUserNetwork(sess.UserID, networkID)
	if err != nil {
		log.Printf("Failed to get network %d for user %s: %v", networkID, sess.Username, err)
		c.JSON(http.StatusNotFound, gin.H{"success": false, "message": "Network not found or you don't own it"})
		return
	}

	// Prepare response, including sensitive fields needed for editing
	responseNetwork := map[string]interface{}{
		"id":              netConfig.ID,
		"network_name":    netConfig.NetworkName,
		"hostname":        netConfig.Hostname,
		"port":            netConfig.Port,
		"use_ssl":         netConfig.UseSSL,
		"server_password": netConfig.ServerPassword, // Include this for editing screen
		"auto_reconnect":  netConfig.AutoReconnect,
		"modules":         netConfig.Modules,
		"perform_commands": netConfig.PerformCommands,
		"initial_channels": netConfig.InitialChannels,
		"nickname":        netConfig.Nickname,
		"alt_nickname":    netConfig.AltNickname,
		"ident":           netConfig.Ident,
		"realname":        netConfig.Realname,
		"quit_message":    netConfig.QuitMessage,
		"is_connected":    netConfig.IsConnected, // Current connection status from session object
	}

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"network": responseNetwork,
	})
}