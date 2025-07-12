package config

type Config struct {
	ListenAddr           string
	ImageBaseDir         string
	AvatarDir            string
	HistoryDuration      string // Duration to keep channel history (e.g. "168h" for 7 days)
	ImageStorageDuration string // Duration to keep uploaded images (e.g. "12h", "24h", "168h")
	UseTLS               bool   // Whether to enable TLS
	TLSCertFile          string // Path to certificate file
	TLSKeyFile           string // Path to private key file
	TLSDomain            string // Domain name for the certificate
	SQLiteDBPath         string // Path to the SQLite database file
	HTTPRedirect         bool   // Whether to redirect HTTP to HTTPS
	HTTPPort             string // Port for HTTP redirects (empty to disable)
}

var Cfg = Config{
	ListenAddr:           "0.0.0.0:8585", // HTTPS port
	ImageBaseDir:         "./images",
	AvatarDir:            "./avatars",
	HistoryDuration:      "168h", // 7 days (168 hours)
	ImageStorageDuration: "12h", // 12 hours
	UseTLS:               true,           // Enable TLS in production
	TLSCertFile:          "fullchain.pem",
	TLSKeyFile:           "privkey.pem",
	TLSDomain:            "orbit-demo.signalseverywhere.net", // Your domain
	HTTPRedirect:         true,           // Enable HTTP->HTTPS redirect
	HTTPPort:             "",            // HTTP redirect port
	SQLiteDBPath:         "./users.db",  // Default SQLite DB file
}