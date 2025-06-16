package session

import (
	"sync"

	"iris-gateway/irc"
)

type UserSession struct {
	Username string
	IRC      *irc.IRCClient
}

var (
	sessionMap = make(map[string]*UserSession)
	mutex      sync.RWMutex
)

func AddSession(token string, s *UserSession) {
	mutex.Lock()
	defer mutex.Unlock()
	sessionMap[token] = s
}

func GetSession(token string) (*UserSession, bool) {
	mutex.RLock()
	defer mutex.RUnlock()
	s, ok := sessionMap[token]
	return s, ok
}

func RemoveSession(token string) {
	mutex.Lock()
	defer mutex.Unlock()
	delete(sessionMap, token)
}
