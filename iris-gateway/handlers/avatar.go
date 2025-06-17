package handlers

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/session"
)

// UploadAvatarHandler handles the upload of user avatars.
// It expects a multipart form with a file field named "avatar".
// The uploaded file will be named after the username and stored in the configured avatar directory.
func UploadAvatarHandler(c *gin.Context) {
	token, ok := getToken(c) // Now getToken is available from helpers.go
	if !ok {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
		return
	}

	sess, found := session.GetSession(token)
	if !found {
		c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
		return
	}

	// Retrieve the file from the form data
	file, err := c.FormFile("avatar")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": fmt.Sprintf("Error retrieving avatar file: %v", err)})
		return
	}

	// Get the file extension
	ext := filepath.Ext(file.Filename)
	if ext == "" {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Could not determine file type. Please upload a file with an extension (e.g., .jpg, .png)"})
		return
	}

	// Validate file type (simple check based on extension)
	allowedExtensions := map[string]bool{
		".jpg":  true,
		".jpeg": true,
		".png":  true,
		".gif":  true,
	}
	if !allowedExtensions[strings.ToLower(ext)] {
		c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Unsupported file type. Only JPG, JPEG, PNG, GIF are allowed."})
		return
	}


	// Construct the filename using the username (overwrite old one)
	filename := fmt.Sprintf("%s%s", sess.Username, ext)
	filePath := filepath.Join(config.Cfg.AvatarDir, filename)

	// Save the uploaded file
	if err := c.SaveUploadedFile(file, filePath); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": fmt.Sprintf("Failed to save avatar: %v", err)})
		return
	}

	// Construct the URL for the avatar
	avatarURL := fmt.Sprintf("/avatars/%s", filename) // Relative URL for the static server

	c.JSON(http.StatusOK, gin.H{
		"success":   true,
		"message":   "Avatar uploaded successfully",
		"avatarUrl": avatarURL,
	})
}