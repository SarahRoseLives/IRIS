// lib/config.dart

// Set this to true if you are running on an Android emulator or a physical Android device
// and your Go backend is running on your host machine's localhost.
// '10.0.2.2' is a special alias for your host machine's localhost from within an Android emulator.
// For physical Android devices connected to the same network as your host, use your host's local IP address.
const bool isAndroidEmulator = false; // <--- Set to true for Android Emulator/Device pointing to localhost, false for Linux/Web/iOS Simulator or production/VPS deployment.

// The nickname of the gateway bot.
// This should match the GatewayNick value used on the gateway server.
const String gatewayNick = "iris-Gateway";


// Define your API host and port
// IMPORTANT: If deploying to a VPS, change "orbit-demo.signalseverywhere.net" to your actual server's
// domain name or public IP address.
const String _apiHostAddress = "orbit-demo.signalseverywhere.net"; // Update with your server IP or domain if needed
const String _apiHostEmulator = "10.0.2.2"; // Android emulator's loopback to host
const int apiPort = 8585;

// Determine the active API host based on the flag
String get apiHost {
  return isAndroidEmulator ? _apiHostEmulator : _apiHostAddress;
}

// Full base URL for HTTP API calls
String get baseUrl {
  return "https://$apiHost:$apiPort/api";
}

// Full base URL for assets, like avatars and attachments
String get baseSecureUrl {
  return "https://$apiHost:$apiPort";
}

// Full base URL for WebSocket connections
String get websocketUrl {
  return "wss://$apiHost:$apiPort/ws"; // Using WSS for secure WebSocket
}