package irc

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
)

// Message struct now includes NetworkID
type Message struct {
	NetworkID int       `json:"network_id"` // New field
	Channel   string    `json:"channel"`
	Sender    string    `json:"sender"`
	Text      string    `json:"text"`
	Timestamp time.Time `json:"timestamp"`
}

// ChannelHistory holds messages for a specific channel on a specific network
type ChannelHistory struct {
	Messages []Message
	mutex    sync.RWMutex
}

// historyMap stores history: Key is "networkID_channelName" (e.g., "1_#general")
var historyMap = make(map[string]*ChannelHistory)
var historyMapMutex sync.RWMutex

// Global history duration (can be moved to config if needed)
var historyDuration = 7 * 24 * time.Hour // Default 7 days

func InitHistory(duration string) {
	parsedDuration, err := time.ParseDuration(duration)
	if err != nil {
		log.Printf("[History] Invalid history duration '%s', using default 7 days", duration)
		historyDuration = 7 * 24 * time.Hour
	} else {
		historyDuration = parsedDuration
	}
	log.Printf("[History] History will be kept for %v", historyDuration)
}

// AddMessageToHistory adds a message to the history for a specific network and channel.
func AddMessageToHistory(networkID int, channel string, message Message) {
	channelKey := fmt.Sprintf("%d_%s", networkID, strings.ToLower(channel))
	historyMapMutex.Lock()
	chHistory, exists := historyMap[channelKey]
	if !exists {
		chHistory = &ChannelHistory{
			Messages: make([]Message, 0),
		}
		historyMap[channelKey] = chHistory
		log.Printf("[History] Created new history slice for network %d, channel: %s", networkID, channelKey)
	}
	historyMapMutex.Unlock() // Unlock historyMapMutex before locking chHistory.mutex

	chHistory.mutex.Lock()
	defer chHistory.mutex.Unlock()

	chHistory.Messages = append(chHistory.Messages, message)

	// Clean up old messages
	cutoff := time.Now().Add(-historyDuration)
	var firstValidIndex = -1
	for i, msg := range chHistory.Messages {
		if msg.Timestamp.After(cutoff) {
			firstValidIndex = i
			break
		}
	}
	if firstValidIndex > 0 {
		chHistory.Messages = chHistory.Messages[firstValidIndex:]
		log.Printf("[History] Pruned %d old messages from network %d, channel %s. Remaining: %d", firstValidIndex, networkID, channelKey, len(chHistory.Messages))
	} else if firstValidIndex == -1 && len(chHistory.Messages) > 0 {
		chHistory.Messages = []Message{} // All messages are old
		log.Printf("[History] All messages in network %d, channel %s were old. History cleared.", networkID, channelKey)
	}
}

// GetChannelHistory retrieves messages for a specific network and channel.
func GetChannelHistory(networkID int, channel string, limit int) []Message {
	channelKey := fmt.Sprintf("%d_%s", networkID, strings.ToLower(channel))
	historyMapMutex.RLock()
	chHistory, exists := historyMap[channelKey]
	historyMapMutex.RUnlock()

	if !exists {
		log.Printf("[History] No history found for network %d, channel %s", networkID, channelKey)
		return nil
	}

	chHistory.mutex.RLock()
	defer chHistory.mutex.RUnlock()

	if len(chHistory.Messages) == 0 {
		log.Printf("[History] Network %d, channel %s history is empty", networkID, channelKey)
		return nil
	}

	if limit <= 0 || limit >= len(chHistory.Messages) {
		// Return a copy to avoid race conditions on the slice
		messagesCopy := make([]Message, len(chHistory.Messages))
		copy(messagesCopy, chHistory.Messages)
		return messagesCopy
	}

	// Return a copy of the slice segment (most recent 'limit' messages)
	start := len(chHistory.Messages) - limit
	messagesCopy := make([]Message, limit)
	copy(messagesCopy, chHistory.Messages[start:])
	return messagesCopy
}