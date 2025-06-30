package events

// WsEvent struct matches the Flutter client's expected event format.
// It is used for marshaling JSON to be sent over the WebSocket.
type WsEvent struct {
	Type    string      `json:"type"`
	Payload interface{} `json:"payload"`
}

// Define expected event types
const (
	EventTypeMessage        = "message"
	EventTypeHistoryMessage = "history_message"
	EventTypeChannelJoin    = "channel_join"
	EventTypeChannelPart    = "channel_part"
	EventTypeMembersUpdate  = "members_update"
	EventTypeConnected      = "connected"
	EventTypeUserAway       = "user_away"
	EventTypeUserBack       = "user_back"
	EventTypeTopicChange    = "topic_change" // New event type for topic changes
	EventTypeNotice         = "notice"         // New event type for IRC notices
)
