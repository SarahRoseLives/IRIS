package users

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	// "strings" // Remove this unused import
	"time"

	"golang.org/x/crypto/bcrypt"
	_ "github.com/mattn/go-sqlite3" // SQLite driver
	"iris-gateway/session" // Import the session package
)

// User represents a user in the system
type User struct {
	ID             int
	Username       string
	HashedPassword string
	IsSuspended    bool
	CreatedAt      time.Time
}

var db *sql.DB

// InitDB initializes the SQLite database and creates the users and irc_networks tables if they don't exist.
func InitDB(dataSourceName string) error {
	var err error
	db, err = sql.Open("sqlite3", dataSourceName)
	if err != nil {
		return fmt.Errorf("failed to open database: %w", err)
	}

	createUsersTableSQL := `
	CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		username TEXT NOT NULL UNIQUE,
		hashed_password TEXT NOT NULL,
		is_suspended BOOLEAN DEFAULT FALSE,
		created_at DATETIME DEFAULT CURRENT_TIMESTAMP
	);`

	_, err = db.Exec(createUsersTableSQL)
	if err != nil {
		return fmt.Errorf("failed to create users table: %w", err)
	}

	// New table for IRC network configurations
	createIRCNetworksTableSQL := `
	CREATE TABLE IF NOT EXISTS irc_networks (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL,
		network_name TEXT NOT NULL,
		hostname TEXT NOT NULL,
		port INTEGER NOT NULL,
		use_ssl BOOLEAN NOT NULL,
		server_password TEXT,
		auto_reconnect BOOLEAN NOT NULL,
		modules TEXT, -- JSON array of strings
		perform_commands TEXT, -- JSON array of strings
		initial_channels TEXT, -- JSON array of strings
		nickname TEXT NOT NULL,
		alt_nickname TEXT,
		ident TEXT,
		realname TEXT,
		quit_message TEXT,
		FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
		UNIQUE(user_id, network_name) -- Ensure unique network name per user
	);`

	_, err = db.Exec(createIRCNetworksTableSQL)
	if err != nil {
		return fmt.Errorf("failed to create irc_networks table: %w", err)
	}

	log.Println("User and IRC network databases initialized.")
	return nil
}

// CreateUser hashes the password and inserts a new user into the database.
func CreateUser(username, password string) error {
	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("failed to hash password: %w", err)
	}

	_, err = db.Exec(
		"INSERT INTO users (username, hashed_password) VALUES (?, ?)",
		username,
		string(hashedPassword),
	)
	if err != nil {
		return fmt.Errorf("failed to create user: %w", err)
	}
	return nil
}

// AuthenticateUser checks the provided username and password against the database.
// It returns the User object if authentication is successful, otherwise an error.
func AuthenticateUser(username, password string) (*User, error) {
	user := &User{}
	err := db.QueryRow(
		"SELECT id, username, hashed_password, is_suspended, created_at FROM users WHERE username = ?",
		username,
	).Scan(&user.ID, &user.Username, &user.HashedPassword, &user.IsSuspended, &user.CreatedAt)

	if err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("user not found")
		}
		return nil, fmt.Errorf("database query error: %w", err)
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.HashedPassword), []byte(password)); err != nil {
		return nil, fmt.Errorf("invalid password")
	}

	return user, nil
}

// DeleteUser removes a user from the database.
func DeleteUser(username string) error {
	result, err := db.Exec("DELETE FROM users WHERE username = ?", username)
	if err != nil {
		return fmt.Errorf("failed to delete user: %w", err)
	}
	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return fmt.Errorf("user '%s' not found", username)
	}
	return nil
}

// SuspendUser sets the is_suspended flag to true for a given user.
func SuspendUser(username string) error {
	result, err := db.Exec("UPDATE users SET is_suspended = TRUE WHERE username = ?", username)
	if err != nil {
		return fmt.Errorf("failed to suspend user: %w", err)
	}
	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return fmt.Errorf("user '%s' not found", username)
	}
	return nil
}

// UnsuspendUser sets the is_suspended flag to false for a given user.
func UnsuspendUser(username string) error {
	result, err := db.Exec("UPDATE users SET is_suspended = FALSE WHERE username = ?", username)
	if err != nil {
		return fmt.Errorf("failed to unsuspend user: %w", err)
	}
	rowsAffected, _ := result.RowsAffected()
	if rowsAffected == 0 {
		return fmt.Errorf("user '%s' not found", username)
	}
	return nil
}

// GetUserByUsername retrieves a user by their username.
func GetUserByUsername(username string) (*User, error) {
	user := &User{}
	err := db.QueryRow(
		"SELECT id, username, hashed_password, is_suspended, created_at FROM users WHERE username = ?",
		username,
	).Scan(&user.ID, &user.Username, &user.HashedPassword, &user.IsSuspended, &user.CreatedAt)

	if err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("user not found")
		}
		return nil, fmt.Errorf("database query error: %w", err)
	}
	return user, nil
}

// CloseDB closes the database connection. Should be called on application shutdown.
func CloseDB() {
	if db != nil {
		db.Close()
		log.Println("User database connection closed.")
	}
}

// AddUserNetwork adds a new IRC network configuration for a user.
func AddUserNetwork(userID int, netConfig *session.UserNetwork) (int, error) {
	modulesJSON, err := json.Marshal(netConfig.Modules)
	if err != nil {
		return 0, fmt.Errorf("failed to marshal modules: %w", err)
	}
	performCommandsJSON, err := json.Marshal(netConfig.PerformCommands)
	if err != nil {
		return 0, fmt.Errorf("failed to marshal perform commands: %w", err)
	}
	initialChannelsJSON, err := json.Marshal(netConfig.InitialChannels)
	if err != nil {
		return 0, fmt.Errorf("failed to marshal initial channels: %w", err)
	}

	res, err := db.Exec(
		`INSERT INTO irc_networks (user_id, network_name, hostname, port, use_ssl, server_password, auto_reconnect, modules, perform_commands, initial_channels, nickname, alt_nickname, ident, realname, quit_message)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		userID,
		netConfig.NetworkName,
		netConfig.Hostname,
		netConfig.Port,
		netConfig.UseSSL,
		netConfig.ServerPassword,
		netConfig.AutoReconnect,
		string(modulesJSON),
		string(performCommandsJSON),
		string(initialChannelsJSON),
		netConfig.Nickname,
		netConfig.AltNickname,
		netConfig.Ident,
		netConfig.Realname,
		netConfig.QuitMessage,
	)
	if err != nil {
		return 0, fmt.Errorf("failed to add user network: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, fmt.Errorf("failed to get last insert ID: %w", err)
	}
	return int(id), nil
}

// GetUserNetworks retrieves all IRC network configurations for a given user.
func GetUserNetworks(userID int) ([]*session.UserNetwork, error) {
	rows, err := db.Query("SELECT id, network_name, hostname, port, use_ssl, server_password, auto_reconnect, modules, perform_commands, initial_channels, nickname, alt_nickname, ident, realname, quit_message FROM irc_networks WHERE user_id = ?", userID)
	if err != nil {
		return nil, fmt.Errorf("failed to get user networks: %w", err)
	}
	defer rows.Close()

	var networks []*session.UserNetwork
	for rows.Next() {
		var netConfig session.UserNetwork
		var modulesJSON, performCommandsJSON, initialChannelsJSON sql.NullString
		var serverPassword sql.NullString
		var altNickname, ident, realname, quitMessage sql.NullString

		err := rows.Scan(
			&netConfig.ID,
			&netConfig.NetworkName,
			&netConfig.Hostname,
			&netConfig.Port,
			&netConfig.UseSSL,
			&serverPassword,
			&netConfig.AutoReconnect,
			&modulesJSON,
			&performCommandsJSON,
			&initialChannelsJSON,
			&netConfig.Nickname,
			&altNickname,
			&ident,
			&realname,
			&quitMessage,
		)
		if err != nil {
			return nil, fmt.Errorf("failed to scan user network row: %w", err)
		}

		if serverPassword.Valid {
			netConfig.ServerPassword = serverPassword.String
		}
		if altNickname.Valid {
			netConfig.AltNickname = altNickname.String
		}
		if ident.Valid {
			netConfig.Ident = ident.String
		}
		if realname.Valid {
			netConfig.Realname = realname.String
		}
		if quitMessage.Valid {
			netConfig.QuitMessage = quitMessage.String
		}

		if modulesJSON.Valid && modulesJSON.String != "" {
			if err := json.Unmarshal([]byte(modulesJSON.String), &netConfig.Modules); err != nil {
				log.Printf("Warning: Failed to unmarshal modules for network %d: %v", netConfig.ID, err)
			}
		} else {
			netConfig.Modules = []string{}
		}
		if performCommandsJSON.Valid && performCommandsJSON.String != "" {
			if err := json.Unmarshal([]byte(performCommandsJSON.String), &netConfig.PerformCommands); err != nil {
				log.Printf("Warning: Failed to unmarshal perform commands for network %d: %v", netConfig.ID, err)
			}
		} else {
			netConfig.PerformCommands = []string{}
		}
		if initialChannelsJSON.Valid && initialChannelsJSON.String != "" {
			if err := json.Unmarshal([]byte(initialChannelsJSON.String), &netConfig.InitialChannels); err != nil {
				log.Printf("Warning: Failed to unmarshal initial channels for network %d: %v", netConfig.ID, err)
			}
		} else {
			netConfig.InitialChannels = []string{}
		}

		netConfig.UserID = userID // Set UserID
		networks = append(networks, &netConfig)
	}
	return networks, nil
}

// GetSingleUserNetwork retrieves a single IRC network configuration for a given user and network ID.
func GetSingleUserNetwork(userID, networkID int) (*session.UserNetwork, error) {
	var netConfig session.UserNetwork
	var modulesJSON, performCommandsJSON, initialChannelsJSON sql.NullString
	var serverPassword sql.NullString
	var altNickname, ident, realname, quitMessage sql.NullString

	err := db.QueryRow(
		`SELECT id, network_name, hostname, port, use_ssl, server_password, auto_reconnect, modules, perform_commands, initial_channels, nickname, alt_nickname, ident, realname, quit_message
		 FROM irc_networks WHERE user_id = ? AND id = ?`,
		userID, networkID,
	).Scan(
		&netConfig.ID,
		&netConfig.NetworkName,
		&netConfig.Hostname,
		&netConfig.Port,
		&netConfig.UseSSL,
		&serverPassword,
		&netConfig.AutoReconnect,
		&modulesJSON,
		&performCommandsJSON,
		&initialChannelsJSON,
		&netConfig.Nickname,
		&altNickname,
		&ident,
		&realname,
		&quitMessage,
	)

	if err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("network config with ID %d not found for user %d", networkID, userID)
		}
		return nil, fmt.Errorf("database query error: %w", err)
	}

	if serverPassword.Valid {
		netConfig.ServerPassword = serverPassword.String
	}
	if altNickname.Valid {
		netConfig.AltNickname = altNickname.String
	}
	if ident.Valid {
		netConfig.Ident = ident.String
	}
	if realname.Valid {
		netConfig.Realname = realname.String
	}
	if quitMessage.Valid {
		netConfig.QuitMessage = quitMessage.String
	}

	if modulesJSON.Valid && modulesJSON.String != "" {
		if err := json.Unmarshal([]byte(modulesJSON.String), &netConfig.Modules); err != nil {
			log.Printf("Warning: Failed to unmarshal modules for network %d: %v", netConfig.ID, err)
			netConfig.Modules = []string{} // Default to empty slice on error
		}
	} else {
		netConfig.Modules = []string{}
	}
	if performCommandsJSON.Valid && performCommandsJSON.String != "" {
		if err := json.Unmarshal([]byte(performCommandsJSON.String), &netConfig.PerformCommands); err != nil {
			log.Printf("Warning: Failed to unmarshal perform commands for network %d: %v", netConfig.ID, err)
			netConfig.PerformCommands = []string{} // Default to empty slice on error
		}
	} else {
		netConfig.PerformCommands = []string{}
	}
	if initialChannelsJSON.Valid && initialChannelsJSON.String != "" {
		if err := json.Unmarshal([]byte(initialChannelsJSON.String), &netConfig.InitialChannels); err != nil {
			log.Printf("Warning: Failed to unmarshal initial channels for network %d: %v", netConfig.ID, err)
			netConfig.InitialChannels = []string{} // Default to empty slice on error
		}
	} else {
		netConfig.InitialChannels = []string{}
	}

	netConfig.UserID = userID // Set UserID
	// Note: is_connected and Channels (live state) are not stored in DB,
	// so they will be default zero values. This is fine as the client
	// will fetch live state separately via WebSocket.
	netConfig.Channels = make(map[string]*session.ChannelState) // Ensure map is initialized

	return &netConfig, nil
}

// UpdateUserNetwork updates an existing IRC network configuration.
func UpdateUserNetwork(userID int, netConfig *session.UserNetwork) error {
	modulesJSON, err := json.Marshal(netConfig.Modules)
	if err != nil {
		return fmt.Errorf("failed to marshal modules: %w", err)
	}
	performCommandsJSON, err := json.Marshal(netConfig.PerformCommands)
	if err != nil {
		return fmt.Errorf("failed to marshal perform commands: %w", err)
	}
	initialChannelsJSON, err := json.Marshal(netConfig.InitialChannels)
	if err != nil {
		return fmt.Errorf("failed to marshal initial channels: %w", err)
	}

	res, err := db.Exec(
		`UPDATE irc_networks SET network_name = ?, hostname = ?, port = ?, use_ssl = ?, server_password = ?,
		auto_reconnect = ?, modules = ?, perform_commands = ?, initial_channels = ?, nickname = ?,
		alt_nickname = ?, ident = ?, realname = ?, quit_message = ?
		WHERE id = ? AND user_id = ?`,
		netConfig.NetworkName,
		netConfig.Hostname,
		netConfig.Port,
		netConfig.UseSSL,
		netConfig.ServerPassword,
		netConfig.AutoReconnect,
		string(modulesJSON),
		string(performCommandsJSON),
		string(initialChannelsJSON),
		netConfig.Nickname,
		netConfig.AltNickname,
		netConfig.Ident,
		netConfig.Realname,
		netConfig.QuitMessage,
		netConfig.ID,
		userID,
	)
	if err != nil {
		return fmt.Errorf("failed to update user network: %w", err)
	}
	rowsAffected, _ := res.RowsAffected()
	if rowsAffected == 0 {
		return fmt.Errorf("network config with ID %d not found for user %d", netConfig.ID, userID)
	}
	return nil
}

// DeleteUserNetwork deletes an IRC network configuration.
func DeleteUserNetwork(userID, networkID int) error {
	res, err := db.Exec("DELETE FROM irc_networks WHERE id = ? AND user_id = ?", networkID, userID)
	if err != nil {
		return fmt.Errorf("failed to delete user network: %w", err)
	}
	rowsAffected, _ := res.RowsAffected()
	if rowsAffected == 0 {
		return fmt.Errorf("network config with ID %d not found for user %d", networkID, userID)
	}
	return nil
}