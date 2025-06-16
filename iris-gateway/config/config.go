package config

type Config struct {
	ErgoAPIURL   string
	BearerToken  string
	ListenAddr   string
	ImageBaseDir string

	IRCServer string
}

var Cfg = Config{ // Capitalized to export
	ErgoAPIURL:   "http://127.0.0.1:8089/v1/check_auth",
	BearerToken:  "SbtZYLpbLAsg6D3TzS_haShbLy3sqQSQb-Yk9I5JNqA",
	ListenAddr:   "0.0.0.0:8080",
	ImageBaseDir: "./images",

	IRCServer:    "localhost:6667", // replace with your actual IRC server address
}
