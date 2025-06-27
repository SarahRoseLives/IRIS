package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/handlers"
	"iris-gateway/irc"
	"iris-gateway/push"
)

func main() {
	// Initialize Firebase Cloud Messaging
	push.InitFCM() // <-- Initialize FCM

	// Initialize the IRC gateway bot
	if err := irc.InitGatewayBot(); err != nil {
		log.Fatalf("Failed to initialize IRC gateway bot: %v", err)
	}

	// Clean up any files older than configured duration on startup
	go func() {
		files, err := os.ReadDir(config.Cfg.ImageBaseDir)
		if err != nil && !os.IsNotExist(err) {
			log.Printf("Failed to read image directory for cleanup: %v", err)
			return
		}

		// Parse the image storage duration from config
		duration, err := time.ParseDuration(config.Cfg.ImageStorageDuration)
		if err != nil {
			log.Printf("Invalid image storage duration '%s', defaulting to 12h", config.Cfg.ImageStorageDuration)
			duration = 12 * time.Hour
		}

		for _, file := range files {
			info, err := file.Info()
			if err != nil {
				continue
			}

			if time.Since(info.ModTime()) > duration {
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

	// ---- CORS Middleware ----
	// For development, allow all origins.
	router.Use(cors.Default())

	// For production, use this instead:
	/*
	router.Use(cors.New(cors.Config{
		AllowOrigins:     []string{"http://localhost:38807"}, // your Flutter web address
		AllowMethods:     []string{"GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"},
		AllowHeaders:     []string{"Origin", "Content-Type", "Accept", "Authorization"},
		ExposeHeaders:    []string{"Content-Length"},
		AllowCredentials: true,
		MaxAge: 12 * time.Hour,
	}))
	*/

	// Serve static avatar files
	router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))

	// Serve static images (attachments)
	router.StaticFS("/images", http.Dir(config.Cfg.ImageBaseDir))

	router.POST("/api/login", handlers.LoginHandler)
	router.POST("/api/channels/join", handlers.JoinChannelHandler)
	router.POST("/api/channels/part", handlers.PartChannelHandler)
	router.GET("/api/channels", handlers.ListChannelsHandler)
	router.GET("/ws/:token", handlers.WebSocketHandler)
	router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)

	// New route for uploading images/attachments
	router.POST("/api/upload-attachment", handlers.UploadAttachmentHandler)

	// New route for registering FCM token
	router.POST("/api/register-fcm-token", handlers.RegisterFCMTokenHandler)

	// New route for channel history
	router.GET("/api/history/:channel", handlers.ChannelHistoryHandler)

	router.Run(config.Cfg.ListenAddr)
}