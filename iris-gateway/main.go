// main.go
package main

import (
	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/handlers"
	"iris-gateway/push" // <-- Import the new push package
	"net/http"
)

func main() {
	// Initialize Firebase Cloud Messaging
	push.InitFCM() // <-- Initialize FCM

	router := gin.Default()

	// Serve static avatar files
	router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))

	router.POST("/api/login", handlers.LoginHandler)
	router.POST("/api/channels/join", handlers.JoinChannelHandler)
	router.POST("/api/channels/part", handlers.PartChannelHandler)
	router.GET("/api/channels", handlers.ListChannelsHandler)
	router.GET("/api/channels/:channelName/messages", handlers.GetChannelMessagesHandler)
	router.GET("/ws/:token", handlers.WebSocketHandler)
	router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)

	// New route for registering FCM token
	router.POST("/api/register-fcm-token", handlers.RegisterFCMTokenHandler) // <-- Add new route

	router.Run(config.Cfg.ListenAddr)
}