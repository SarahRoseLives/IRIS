// handlers/push.go
package handlers

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"iris-gateway/session"
)

type RegisterFCMTokenRequest struct {
	FCMToken string `json:"fcm_token"`
}

// RegisterFCMTokenHandler handles registering a device's FCM token.
func RegisterFCMTokenHandler(c *gin.Context) {
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

	var req RegisterFCMTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid request body"})
		return
	}

	if req.FCMToken == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "fcm_token is required"})
		return
	}

	sess.Mutex.Lock()
	sess.FCMToken = req.FCMToken
	sess.Mutex.Unlock()

	log.Printf("[FCM] Registered FCM token for user %s", sess.Username)

	c.JSON(http.StatusOK, gin.H{"success": true, "message": "FCM token registered successfully"})
}