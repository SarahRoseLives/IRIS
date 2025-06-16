# Iris - IRC Interface System

**Modern chat, timeless protocol.**

Iris is a sleek, mobile-first chat application that brings modern UX to the IRC protocol. Featuring a clean, Discord-inspired interface, Iris makes traditional IRC networks feel like modern chat platforms. Built with a Go-based gateway and a Flutter-powered client, Iris adds support for images, avatars, and real-time messaging---all while staying true to IRC fundamentals.

---

## ✨ Features

- 📱 **Beautiful Android client** with modern chat UI
- 🌐 **Gateway server** connects to an Ergo IRC Server
  - Allows us to place a websocket interface between IRC and the Flutter/Android Client
- 🖼️ **Embedded media** support including avatars and images
- 🔐 **NickServ authentication** for secure identity
- 💬 **Discord-style experience** with channel lists, DMs, and more
  - Work in progress

---

## 📸 Screenshots

### Login Screen
![Login](screenshots/login.jpg)

### Logged-In Interface
![Logged In](screenshots/logged_in.jpg)

### Emoji Support (Plain Text Emoji Only)
![Logged In](screenshots/emoji.jpg)
---

## 🛠️ Tech Stack

- **Frontend:** Flutter
- **Backend Gateway:** Go
- **Protocol:** IRC + custom metadata layer
- **Auth:** Ergo IRC API (`/v1/check_auth`)