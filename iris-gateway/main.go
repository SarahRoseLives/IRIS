package main

import (
    "crypto/tls"
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
    push.InitFCM()

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

    // CORS Middleware
    router.Use(cors.Default())

    // Serve static avatar files
    router.StaticFS("/avatars", http.Dir(config.Cfg.AvatarDir))

    // Serve static images (attachments)
    router.StaticFS("/images", http.Dir(config.Cfg.ImageBaseDir))

    // API routes
    router.POST("/api/login", handlers.LoginHandler)
    router.POST("/api/channels/join", handlers.JoinChannelHandler)
    router.POST("/api/channels/part", handlers.PartChannelHandler)
    router.GET("/api/channels", handlers.ListChannelsHandler)
    router.GET("/ws/:token", handlers.WebSocketHandler)
    router.POST("/api/upload-avatar", handlers.UploadAvatarHandler)
    router.POST("/api/upload-attachment", handlers.UploadAttachmentHandler)
    router.POST("/api/register-fcm-token", handlers.RegisterFCMTokenHandler)
    router.GET("/api/history/:channel", handlers.ChannelHistoryHandler)

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

        // Optionally start HTTP->HTTPS redirect server if enabled
        if config.Cfg.HTTPRedirect && config.Cfg.HTTPPort != "" {
            go func() {
                log.Printf("Starting HTTP redirect server on %s", config.Cfg.HTTPPort)
                if err := http.ListenAndServe(config.Cfg.HTTPPort, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                    target := "https://" + config.Cfg.TLSDomain + r.URL.RequestURI()
                    http.Redirect(w, r, target, http.StatusMovedPermanently)
                })); err != nil {
                    log.Printf("HTTP redirect server failed: %v", err)
                }
            }()
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