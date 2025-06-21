package config

type Config struct {
	ErgoAPIURL      string
	BearerToken     string
	ListenAddr      string
	ImageBaseDir    string
	AvatarDir       string
	IRCServer       string
	HistoryDuration string // New field for history duration
}

var Cfg = Config{
	ErgoAPIURL:      "http://127.0.0.1:8089/v1/check_auth",
	BearerToken:     "SbtZYLpbLAsg6D3TzS_haShbLy3sqQSQb-Yk9I5JNqA",
	ListenAddr:      "0.0.0.0:8080",
	ImageBaseDir:    "./images",
	AvatarDir:       "./avatars",
	IRCServer:       "localhost:6667",
	HistoryDuration: "1d", // Default to 1 day
}
