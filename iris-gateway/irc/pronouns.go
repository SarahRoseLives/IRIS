package irc

import (
	"strings"
	"sync"
)

var (
	// Map to store pronouns by username (case-insensitive)
	userPronouns   = make(map[string]string)
	pronounsMutex  sync.RWMutex
)

// SetPronouns sets the pronouns for a user (case-insensitive nick)
func SetPronouns(nick, pronouns string) {
	pronounsMutex.Lock()
	defer pronounsMutex.Unlock()
	userPronouns[strings.ToLower(nick)] = pronouns
}

// GetPronouns gets the pronouns for a user, returns empty string if not set
func GetPronouns(nick string) string {
	pronounsMutex.RLock()
	defer pronounsMutex.RUnlock()
	return userPronouns[strings.ToLower(nick)]
}