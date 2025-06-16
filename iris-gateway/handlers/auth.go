package handlers

import (
    "bytes"
    "encoding/json"
    "io"
    "net/http"
    "strings"

    "github.com/gin-gonic/gin"
    "github.com/google/uuid"
    "iris-gateway/config"
    "iris-gateway/irc"
    "iris-gateway/session"
)

type LoginRequest struct {
    Username string `json:"username"`
    Password string `json:"password"`
}

func LoginHandler(c *gin.Context) {
    var req LoginRequest
    if err := c.BindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Invalid JSON"})
        return
    }

    req.Username = strings.TrimSpace(req.Username)
    if req.Username == "" || req.Password == "" {
        c.JSON(http.StatusBadRequest, gin.H{"success": false, "message": "Username and password required"})
        return
    }

    // Forward credentials to the Ergo authentication API
    body := map[string]string{
        "accountName": req.Username,
        "passphrase":  req.Password,
    }
    payload, _ := json.Marshal(body)

    httpReq, _ := http.NewRequest("POST", config.Cfg.ErgoAPIURL, bytes.NewReader(payload))
    httpReq.Header.Set("Content-Type", "application/json")
    httpReq.Header.Set("Authorization", "Bearer "+config.Cfg.BearerToken)

    resp, err := http.DefaultClient.Do(httpReq)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "Gateway error"})
        return
    }
    defer resp.Body.Close()

    respData, _ := io.ReadAll(resp.Body)
    var result map[string]interface{}
    _ = json.Unmarshal(respData, &result)

    successVal, exists := result["success"]
    successBool, ok := successVal.(bool)
    if resp.StatusCode != 200 || !exists || !ok || !successBool {
        msg, _ := result["message"].(string)
        if msg == "" {
            msg = "Login failed"
        }
        c.JSON(http.StatusUnauthorized, gin.H{"success": false, "message": msg})
        return
    }

    // IRC login step using our updated authentication function
    client, err := irc.AuthenticateWithNickServ(req.Username, req.Password)
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"success": false, "message": "IRC login failed"})
        return
    }

    // Create and store session using a new token.
    token := uuid.New().String()
    session.AddSession(token, &session.UserSession{
        Username: req.Username,
        IRC:      client,
    })

    c.JSON(http.StatusOK, gin.H{
        "success": true,
        "message": "Login successful",
        "token":   token,
    })
}
