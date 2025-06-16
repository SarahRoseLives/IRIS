package main

import (
	"github.com/gin-gonic/gin"
	"iris-gateway/handlers"
	"iris-gateway/config"
)

func main() {
	router := gin.Default()
	router.POST("/api/login", handlers.LoginHandler)
	router.Run(config.Cfg.ListenAddr)
}
