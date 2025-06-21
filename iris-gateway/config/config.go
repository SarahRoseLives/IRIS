package config

type Config struct {
	ErgoAPIURL       string
	BearerToken      string
	ListenAddr       string
	ImageBaseDir     string
	AvatarDir        string
	IRCServer        string
	HistoryDuration  string // Duration to keep channel history (e.g. "168h" for 7 days)
	GatewayNick      string // Nickname for the gateway bot
	GatewayPassword  string // Password for the gateway bot (for SASL)
}

var Cfg = Config{
	ErgoAPIURL:      "http://127.0.0.1:8089/v1/check_auth",
	BearerToken:     "SbtZYLpbLAsg6D3TzS_haShbLy3sqQSQb-Yk9I5JNqA",
	ListenAddr:      "0.0.0.0:8080",
	ImageBaseDir:    "./images",
	AvatarDir:       "./avatars",
	IRCServer:       "localhost:6667",
	HistoryDuration: "168h", // Default to 7 days (168 hours)
	GatewayNick:     "IRSI-Gateway",
	GatewayPassword: "gateway-secret-password",
}
