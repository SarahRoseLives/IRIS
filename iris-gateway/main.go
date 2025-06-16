package main

import (
	"github.com/gin-gonic/gin"
	"iris-gateway/handlers"
	"iris-gateway/config"
)

func main() {
	router := gin.Default()
	router.POST("/api/login", handlers.LoginHandler)
    router.POST("/api/channels/join", handlers.JoinChannelHandler)
    router.POST("/api/channels/part", handlers.PartChannelHandler)
    router.GET("/api/channels", handlers.ListChannelsHandler)
    router.GET("/api/channels/:channelName/messages", handlers.GetChannelMessagesHandler)
    router.GET("/ws/:token", handlers.WebSocketHandler)
	router.Run(config.Cfg.ListenAddr)
}
