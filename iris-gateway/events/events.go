package events

// WsEvent struct matches the Flutter client's expected event format.
// It is used for marshaling JSON to be sent over the WebSocket.
type WsEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// All broadcasting and channel logic has been moved to the session package
// to handle the sync state correctly and avoid circular import dependencies.