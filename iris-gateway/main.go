package main

import (
	"crypto/tls"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-contrib/cors"
	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/handlers"
	"iris-gateway/irc" // Keep this import for the new irc_client and history
	"iris-gateway/push"
	"iris-gateway/users"
)

func main() {
	// Command-line flags for user management
	createUserFlag := flag.String("createuser", "", "Create a new user. Format: --createuser <username>:<password>")
	deleteUserFlag := flag.String("deleteuser", "", "Delete a user. Format: --deleteuser <username>")
	suspendUserFlag := flag.String("suspenduser", "", "Suspend a user. Format: --suspenduser <username>")
	unsuspendUserFlag := flag.String("unsuspenduser", "", "Unsuspend a user. Format: --unsuspenduser <username>")

	flag.Parse()

	// Initialize the user database before any flag operations
	if err := users.InitDB(config.Cfg.SQLiteDBPath); err != nil {
		log.Fatalf("Failed to initialize user database: %v", err)
	}
	defer users.CloseDB()

	// Handle user management commands first
	if *createUserFlag != "" {
		parts := strings.SplitN(*createUserFlag, ":", 2)
		if len(parts) != 2 {
			log.Fatalf("Invalid --createuser format. Use: <username>:<password>")
		}
		username := parts[0]
		password := parts[1]
		if err := users.CreateUser(username, password); err != nil {
			log.Fatalf("Failed to create user %s: %v", username, err)
		}
		log.Printf("User '%s' created successfully.", username)
		return // Exit after user management command
	}

	if *deleteUserFlag != "" {
		if err := users.DeleteUser(*deleteUserFlag); err != nil {
			log.Fatalf("Failed to delete user %s: %v", *deleteUserFlag, err)
		}
		log.Printf("User '%s' deleted successfully.", *deleteUserFlag)
		return // Exit after user management command
	}

	if *suspendUserFlag != "" {
		if err := users.SuspendUser(*suspendUserFlag); err != nil {
			log.Fatalf("Failed to suspend user %s: %v", *suspendUserFlag, err)
		}
		log.Printf("User '%s' suspended successfully.", *suspendUserFlag)
		return // Exit after user management command
	}

	if *unsuspendUserFlag != "" {
		if err := users.UnsuspendUser(*unsuspendUserFlag); err != nil {
			log.Fatalf("Failed to unsuspend user %s: %v", *unsuspendUserFlag, err)
		}
		log.Printf("User '%s' unsuspended successfully.", *unsuspendUserFlag)
		return // Exit after user management command
	}

	// Initialize Firebase Cloud Messaging
	push.InitFCM()

	// Initialize IRC history manager
	irc.InitHistory(config.Cfg.HistoryDuration)

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

	// HTTP->HTTPS redirect logic
	if config.Cfg.HTTPRedirect && config.Cfg.HTTPPort != "" {
		go func() {
			redirect := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				target := "https://" + config.Cfg.TLSDomain + r.URL.RequestURI()
				http.Redirect(w, r, target, http.StatusMovedPermanently)
			})
			log.Printf("Starting HTTP redirect on %s", config.Cfg.HTTPPort)
			if err := http.ListenAndServe(config.Cfg.HTTPPort, redirect); err != nil {
				log.Printf("HTTP redirect failed: %v", err)
			}
		}()
	}

	router := gin.Default()

	// CORS Middleware
	router.Use(cors.Default())

	// Serve static avatar files
	router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))

	// Serve static images (attachments)
	router.StaticFS("/images", http.Dir(config.Cfg.ImageBaseDir))

	// API routes
	router.POST("/api/login", handlers.LoginHandler)
	router.GET("/api/validate-session", handlers.ValidateSessionHandler)
	router.POST("/api/channels/join", handlers.JoinChannelHandler) // Still useful, but needs network_id
	router.POST("/api/channels/part", handlers.PartChannelHandler) // Still useful, but needs network_id
	router.GET("/api/channels", handlers.ListChannelsHandler)      // Needs to list channels per network
	router.GET("/api/history/:networkId/:channel", handlers.ChannelHistoryHandler) // New history endpoint

	// New API endpoints for IRC network management
	router.POST("/api/irc/networks", handlers.AddNetworkHandler)
	router.GET("/api/irc/networks", handlers.ListNetworksHandler)
	router.PUT("/api/irc/networks/:id", handlers.UpdateNetworkHandler)
	router.DELETE("/api/irc/networks/:id", handlers.DeleteNetworkHandler)
	router.POST("/api/irc/networks/:id/connect", handlers.ConnectNetworkHandler)
	router.POST("/api/irc/networks/:id/disconnect", handlers.DisconnectNetworkHandler)

	// Register the new API endpoint for fetching a single IRC network's details
	router.GET("/api/irc/networks/:id", handlers.GetNetworkDetailsHandler)

	router.GET("/ws/:token", handlers.WebSocketHandler)
	router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)
	router.POST("/api/upload-attachment", handlers.UploadAttachmentHandler)
	router.POST("/api/register-fcm-token", handlers.RegisterFCMTokenHandler)

	// Create HTTP server with timeouts
	srv := &http.Server{
		Addr:         config.Cfg.ListenAddr,
		Handler:      router,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	if config.Cfg.UseTLS {
		// Verify certificates exist
		if _, err := os.Stat(config.Cfg.TLSCertFile); os.IsNotExist(err) {
			log.Fatalf("Certificate file not found: %s", config.Cfg.TLSCertFile)
		}
		if _, err := os.Stat(config.Cfg.TLSKeyFile); os.IsNotExist(err) {
			log.Fatalf("Key file not found: %s", config.Cfg.TLSKeyFile)
		}

		// Configure TLS with your certificate files
		cert, err := tls.LoadX509KeyPair(config.Cfg.TLSCertFile, config.Cfg.TLSKeyFile)
		if err != nil {
			log.Fatalf("Failed to load TLS certificates: %v", err)
		}

		// Configure TLS with modern settings
		srv.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{cert},
			MinVersion:   tls.VersionTLS12,
			CipherSuites: []uint16{
				tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
				tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
				tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
				tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
				tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
				tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			},
		}

		// Start HTTPS server on configured port (usually 8080)
		log.Printf("Starting HTTPS server on %s", config.Cfg.ListenAddr)
		if err := srv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start HTTPS server: %v", err)
		}
	} else {
		// Start HTTP server
		log.Printf("Starting HTTP server on %s", config.Cfg.ListenAddr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start HTTP server: %v", err)
		}
	}
}