package handlers

import (
    "fmt"
    "net/http"
    "reflect"
    "strings"
    "time"

    "github.com/gin-gonic/gin"
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
    c.JSON(http.StatusOK, gin.H{"success": true, "message": "Join command sent"})
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
    c.JSON(http.StatusOK, gin.H{"success": true, "message": "Part command sent"})
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
