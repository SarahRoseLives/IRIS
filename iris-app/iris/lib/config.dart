// lib/config.dart

// Set this to true if you are running on an Android emulator
// and your Go backend is running on your host machine.
// '10.0.2.2' is a special alias for your host machine's localhost from within an Android emulator.
const bool isAndroidEmulator = false; // <--- Set to true for Android Emulator/Device, false for Linux/Web/iOS Simulator

// Define your API host and port
const String _apiHostAddress = "192.168.1.240";
const String _apiHostEmulator = "10.0.2.2"; // Android emulator's loopback to host
const int apiPort = 8080;

// Determine the active API host based on the flag
String get apiHost {
  return isAndroidEmulator ? _apiHostEmulator : _apiHostAddress;
}

// Full base URL for HTTP API calls
String get baseUrl {
  return "http://$apiHost:$apiPort/api";
}

// Full base URL for WebSocket connections
String get websocketUrl {
  return "ws://$apiHost:$apiPort/ws";
}
