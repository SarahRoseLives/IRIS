package handlers

import (
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"os"

	"github.com/gin-gonic/gin"
	"iris-gateway/config"
	"iris-gateway/session"
)

// UploadAvatarHandler handles the upload of user avatars.
// It expects a multipart form with a file field named "avatar".
// The uploaded file will be named after the username and stored in the configured avatar directory.
// handlers/avatar.go
func UploadAvatarHandler(c *gin.Context) {
    token, ok := getToken(c)
    if !ok {
        c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Missing token"})
        return
    }

    sess, found := session.GetSession(token)
    if !found {
        c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": "Invalid session"})
        return
    }

    file, err := c.FormFile("avatar")
    if err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": fmt.Sprintf("Error retrieving avatar file: %v", err)})
        return
    }

    ext := filepath.Ext(file.Filename)
    if ext == "" {
        c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Could not determine file type"})
        return
    }

    allowedExtensions := map[string]bool{
        ".jpg":  true,
        ".jpeg": true,
        ".png":  true,
        ".gif":  true,
    }
    if !allowedExtensions[strings.ToLower(ext)] {
        c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Unsupported file type"})
        return
    }

    // Create avatars directory if it doesn't exist
    if err := os.MkdirAll(config.Cfg.AvatarDir, 0755); err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Failed to create avatar directory"})
        return
    }

    // Save with username as filename
    filename := fmt.Sprintf("%s%s", sess.Username, ext)
    filePath := filepath.Join(config.Cfg.AvatarDir, filename)

    // Remove old avatar if it exists (with any extension)
    oldFiles, err := filepath.Glob(filepath.Join(config.Cfg.AvatarDir, sess.Username+".*"))
    if err == nil {
        for _, oldFile := range oldFiles {
            os.Remove(oldFile)
        }
    }

    if err := c.SaveUploadedFile(file, filePath); err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": fmt.Sprintf("Failed to save avatar: %v", err)})
        return
    }

    avatarURL := fmt.Sprintf("/avatars/%s", filename)
    c.JSON(http.StatusOK, gin.H{
        "success":   true,
        "message":   "Avatar uploaded successfully",
        "avatarUrl": avatarURL,
    })
}