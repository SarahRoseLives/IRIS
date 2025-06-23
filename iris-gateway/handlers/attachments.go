package handlers

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/session"
)

// UploadAttachmentHandler handles image uploads
func UploadAttachmentHandler(c *gin.Context) {
	token, ok := getToken(c)
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	_, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	// Retrieve the file from the form data
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": fmt.Sprintf("Error retrieving file: %v", err)})
		return
	}

	// Validate it's an image
	ext := strings.ToLower(filepath.Ext(file.Filename))
	allowedExtensions := map[string]bool{
		".jpg":  true,
		".jpeg": true,
		".png":  true,
		".gif":  true,
		".webp": true,
	}
	if !allowedExtensions[ext] {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Only image files are allowed (JPG, PNG, GIF, WEBP)"})
		return
	}

	// Create the images directory if it doesn't exist
	if err := os.MkdirAll(config.Cfg.ImageBaseDir, 0755); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to create upload directory"})
		return
	}

	// Generate a unique filename
	filename := fmt.Sprintf("%d%s", time.Now().UnixNano(), ext)
	filePath := filepath.Join(config.Cfg.ImageBaseDir, filename)

	// Save the uploaded file
	if err := c.SaveUploadedFile(file, filePath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": fmt.Sprintf("Failed to save file: %v", err)})
		return
	}

	// Parse the image storage duration from config
	duration, err := time.ParseDuration(config.Cfg.ImageStorageDuration)
	if err != nil {
		log.Printf("Invalid image storage duration '%s', defaulting to 12h", config.Cfg.ImageStorageDuration)
		duration = 12 * time.Hour
	}

	// Schedule cleanup after configured duration
	time.AfterFunc(duration, func() {
		if err := os.Remove(filePath); err != nil {
			log.Printf("Failed to cleanup attachment %s: %v", filePath, err)
		} else {
			log.Printf("Cleaned up attachment %s", filePath)
		}
	})

	// Return the URL to access the image
	imageURL := fmt.Sprintf("/images/%s", filename)
	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"url":     imageURL,
	})
}