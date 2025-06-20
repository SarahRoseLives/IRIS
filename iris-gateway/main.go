package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/handlers"
	"iris-gateway/push"
)

func main() {
	// Initialize Firebase Cloud Messaging
	push.InitFCM() // <-- Initialize FCM

	// Clean up any files older than 12 hours on startup
	go func() {
		files, err := os.ReadDir(config.Cfg.ImageBaseDir)
		if err != nil && !os.IsNotExist(err) {
			log.Printf("Failed to read image directory for cleanup: %v", err)
			return
		}

		for _, file := range files {
			info, err := file.Info()
			if err != nil {
				continue
			}

			if time.Since(info.ModTime()) > 12*time.Hour {
				path := filepath.Join(config.Cfg.ImageBaseDir, file.Name())
				if err := os.Remove(path); err != nil {
					log.Printf("Failed to cleanup old file %s: %v", path, err)
				} else {
					log.Printf("Cleaned up old file %s", path)
				}
			}
		}
	}()

	router := gin.Default()

	// Serve static avatar files
	router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))

	// Serve static images (attachments)
	router.StaticFS("/images", http.Dir(config.Cfg.ImageBaseDir))

	router.POST("/api/login", handlers.LoginHandler)
	router.POST("/api/channels/join", handlers.JoinChannelHandler)
	router.POST("/api/channels/part", handlers.PartChannelHandler)
	router.GET("/api/channels", handlers.ListChannelsHandler)
	router.GET("/api/channels/:channelName/messages", handlers.GetChannelMessagesHandler)
	router.GET("/ws/:token", handlers.WebSocketHandler)
	router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)

	// New route for uploading images/attachments
	router.POST("/api/upload-attachment", handlers.UploadAttachmentHandler)

	// New route for registering FCM token
	router.POST("/api/register-fcm-token", handlers.RegisterFCMTokenHandler)

	router.Run(config.Cfg.ListenAddr)
}