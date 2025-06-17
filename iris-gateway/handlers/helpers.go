package handlers

import (
	"strings"

	"github.com/gin-gonic/gin"
)

// getToken extracts the Bearer token from the Authorization header.
// It's a helper function intended for use by multiple handlers.
func getToken(c *gin.Context) (string, bool) {
	auth := c.GetHeader("Authorization")
	if strings.HasPrefix(auth, "Bearer ") {
		return strings.TrimPrefix(auth, "Bearer "), true
	}
	return "", false
}