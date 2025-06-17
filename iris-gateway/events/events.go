package events

import (
	"log"
	"sync" // NEW: Import sync for mutex
)

// WsEvent struct matches the Flutter client's expected event format
type WsEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// WsBroadcasterFunc defines the signature for functions that can broadcast a WsEvent.
// A session's Broadcast method will conform to this.
// NEW: This type definition breaks the direct import dependency.
type WsBroadcasterFunc func(eventType string, payload interface{})

// globalBroadcastChannel is a global channel for messages to be broadcast to all connected clients.
var globalBroadcastChannel = make(chan WsEvent, 100) // Buffered channel to prevent blocking senders

// NEW: Map to hold registered broadcaster functions, keyed by a unique ID (e.g., session token).
var activeBroadcasters = make(map[string]WsBroadcasterFunc)
var broadcastersMutex = &sync.RWMutex{} // NEW: Mutex to protect activeBroadcasters map

// init function runs once when the package is imported
func init() {
	// Start the WebSocket broadcaster in a goroutine
	go startWebSocketBroadcaster()
}

// Public function to allow other packages to send events
func SendEvent(eventType string, payload interface{}) {
	globalBroadcastChannel <- WsEvent{
		Type:    eventType,
		Payload: payload,
	}
}

// NEW: RegisterBroadcaster allows a session to register its WebSocket broadcast function.
// The 'id' parameter should be unique per session (e.g., the session token).
func RegisterBroadcaster(id string, fn WsBroadcasterFunc) {
	broadcastersMutex.Lock()
	defer broadcastersMutex.Unlock()
	activeBroadcasters[id] = fn
	log.Printf("[Events] Broadcaster %s registered. Total: %d", id, len(activeBroadcasters))
}

// NEW: UnregisterBroadcaster allows a session to remove its WebSocket broadcast function.
// Call this when a session is closed or no longer needs to receive broadcasts.
func UnregisterBroadcaster(id string) {
	broadcastersMutex.Lock()
	defer broadcastersMutex.Unlock()
	delete(activeBroadcasters, id)
	log.Printf("[Events] Broadcaster %s unregistered. Total: %d", id, len(activeBroadcasters))
}

// startWebSocketBroadcaster listens for messages on the globalBroadcastChannel
// and forwards them to all registered WebSocket broadcast functions.
// MODIFIED: Now iterates over registered broadcasters instead of `session.ForEachSession`.
func startWebSocketBroadcaster() {
	for {
		event := <-globalBroadcastChannel // Blocks until an event is sent
		log.Printf("[Events Broadcaster] Received event for broadcast: Type=%s, Payload=%v", event.Type, event.Payload)

		broadcastersMutex.RLock() // Acquire read lock while iterating
		// Iterate over a copy of the slice of functions to avoid holding the lock
		// if a broadcastFn takes time, and to prevent map modification during iteration.
		// If a broadcastFn panics, we recover and unregister it.
		for id, broadcastFn := range activeBroadcasters {
			go func(id string, fn WsBroadcasterFunc, eventType string, payload interface{}) {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("[Events Broadcaster] Recovered from panic in broadcaster %s: %v", id, r)
						// Optionally unregister a panicking broadcaster if it indicates a bad state
						UnregisterBroadcaster(id) // Unregister the problematic broadcaster
					}
				}()
				fn(eventType, payload)
			}(id, broadcastFn, event.Type, event.Payload)
		}
		broadcastersMutex.RUnlock() // Release read lock
	}
}
