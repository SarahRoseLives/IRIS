package main

import (
	"github.com/gin-gonic/gin"
	"iris-gateway/handlers"
	"iris-gateway/config"
	"net/http" // New import for serving static files
)

func main() {
	router := gin.Default()

	// Serve static avatar files
	// This will serve files from the "avatars" directory under the "/avatars" URL path.
	// For example, if a user uploads an avatar named "john.jpg", it will be accessible at /avatars/john.jpg
	router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))


	router.POST("/api/login", handlers.LoginHandler)
	router.POST("/api/channels/join", handlers.JoinChannelHandler)
	router.POST("/api/channels/part", handlers.PartChannelHandler)
	router.GET("/api/channels", handlers.ListChannelsHandler)
	router.GET("/api/channels/:channelName/messages", handlers.GetChannelMessagesHandler)
	router.GET("/ws/:token", handlers.WebSocketHandler)

	// New route for avatar upload
	router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)


	router.Run(config.Cfg.ListenAddr)
}