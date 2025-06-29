package config

type Config struct {
    ErgoAPIURL           string
    BearerToken          string
    ListenAddr           string
    ImageBaseDir         string
    AvatarDir            string
    IRCServer            string
    HistoryDuration      string // Duration to keep channel history (e.g. "168h" for 7 days)
    GatewayNick          string // Nickname for the gateway bot
    GatewayPassword      string // Password for the gateway bot (for SASL)
    ImageStorageDuration string // Duration to keep uploaded images (e.g. "12h", "24h", "168h")
    UseTLS               bool   // Whether to enable TLS
    TLSCertFile          string // Path to certificate file
    TLSKeyFile           string // Path to private key file
    TLSDomain            string // Domain name for the certificate
    HTTPRedirect         bool   // Whether to redirect HTTP to HTTPS
    HTTPPort             string // Port for HTTP redirects (empty to disable)
}

var Cfg = Config{
    ErgoAPIURL:           "http://127.0.0.1:8089/v1/check_auth",
    BearerToken:          "SbtZYLpbLAsg6D3TzS_haShbLy3sqQSQb-Yk9I5JNqA",
    ListenAddr:           "0.0.0.0:8080", // HTTPS port
    ImageBaseDir:         "./images",
    AvatarDir:            "./avatars",
    IRCServer:            "localhost:6667",
    HistoryDuration:      "168h", // 7 days (168 hours)
    GatewayNick:          "IRSI-Gateway",
    GatewayPassword:      "gateway-secret-password",
    ImageStorageDuration: "12h", // 12 hours
    UseTLS:               true,           // Enable TLS in production
    TLSCertFile:          "/etc/letsencrypt/live/iris.transirc.chat/fullchain.pem",
    TLSKeyFile:           "/etc/letsencrypt/live/iris.transirc.chat/privkey.pem",
    TLSDomain:            "iris.transirc.chat", // Your domain
    HTTPRedirect:         true,           // Enable HTTP->HTTPS redirect
    HTTPPort:             "",        // HTTP redirect port
}