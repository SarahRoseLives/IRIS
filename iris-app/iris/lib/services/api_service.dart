// lib/services/api_service.dart
import 'dart:convert';
import 'dart:io'; // Import for File class
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart'; // Import for MediaType
import '../config.dart'; // For base URL
import '../models/login_response.dart'; // Import the new LoginResponse model

class ApiService {
  // Make _token nullable and initialize without it for the login method
  String? _token;

  ApiService([this._token]); // Optional constructor for token

  // This method should not require a token as it's for initial login
  Future<LoginResponse> login(String username, String password) async {
    final url = Uri.parse('$baseUrl/login');
    print("[ApiService] login: Calling POST $url"); // Added debug print
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );
      print("[ApiService] login: Received status code ${response.statusCode}"); // Added debug print

      // Always try to parse the response with LoginResponse.fromJson
      final responseData = json.decode(response.body);
      return LoginResponse.fromJson(responseData);
    } catch (e) {
      print("[ApiService] login Error: $e"); // Added debug print
      // For any network or parsing error, return a failed LoginResponse
      return LoginResponse(success: false, message: 'Network error during login: $e');
    }
  }

  // Ensure other methods use the token if available
  // If a token is explicitly passed to the constructor, it uses that.
  // Otherwise, you might need to retrieve it from SharedPreferences here,
  // or ensure all calls needing a token are made via an ApiService instance
  // that was correctly initialized with a token.

  // Helper to ensure token is present for authenticated calls
  String _getToken() {
    if (_token == null) {
      throw Exception("Authentication token is not set for ApiService.");
    }
    return _token!;
  }

  /// Fetches the list of channels from the API.
  Future<List<String>> fetchChannels() async {
    final url = Uri.parse('$baseUrl/channels');
    print("[ApiService] fetchChannels: Calling GET $url with token: $_token"); // Added debug print
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );
      print("[ApiService] fetchChannels: Received status code ${response.statusCode}"); // Added debug print

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> apiChannels = data['channels'] ?? [];
        return apiChannels.map((c) => c['name'].toString()).toList();
      } else {
        throw Exception(data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      print("[ApiService] fetchChannels Error: $e"); // Added debug print
      throw Exception("Network error fetching channels: $e");
    }
  }

  /// Fetches messages for a specific channel from the API.
  Future<List<Map<String, dynamic>>> fetchChannelMessages(String channelName) async {
    print("[ApiService] fetchChannelMessages: Attempting to fetch messages for $channelName"); // Added debug print
    if (channelName.isEmpty) {
      print("[ApiService] fetchChannelMessages: Channel name is empty, returning empty list."); // Added debug print
      return [];
    }

    // FIX 1: URL-encode the channel name to handle '#' or other special characters
    // Uri.encodeComponent is used for path segments
    final encodedChannelName = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/channels/$encodedChannelName/messages');
    final token = _getToken(); // Get token before the request
    print("[ApiService] fetchChannelMessages: Calling GET $url with token: $token"); // Added debug print

    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      print("[ApiService] fetchChannelMessages: Received status code ${response.statusCode} for $channelName"); // Added debug print

      print("[ApiService] fetchChannelMessages: Raw response body: ${response.body}");

      final data = jsonDecode(response.body);

      // FIX 2: Remove the `data['success'] == true` check for this endpoint
      // The curl output confirmed that the response for messages directly contains the "messages" field.
      if (response.statusCode == 200) { // Only check for 200 status code
        final List<dynamic> receivedMessages = data['messages'] ?? []; // Access the 'messages' field
        print("[ApiService] fetchChannelMessages: Successfully fetched ${receivedMessages.length} messages for $channelName"); // Added debug print
        return receivedMessages.map((msg) => {
              'from': msg['from'] ?? '',
              'content': msg['content'] ?? '',
              'time': msg['time'] ?? DateTime.now().toIso8601String(),
            }).toList();
      } else {
        // If status is not 200, assume an error, and try to get a message from the response
        print("[ApiService] fetchChannelMessages: API returned non-200 status for $channelName: ${response.statusCode}"); // Added debug print
        throw Exception("Failed to load messages: Status ${response.statusCode}, Body: ${response.body}");
      }
    } catch (e) {
      print("[ApiService] fetchChannelMessages Error for $channelName: $e"); // Added debug print
      throw Exception("Network error fetching messages: $e");
    }
  }

  Future<Map<String, dynamic>> joinChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/join');
    print("[ApiService] joinChannel: Calling POST $url for channel $channelName"); // Added debug print
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );
    final responseData = json.decode(response.body);
    print("[ApiService] joinChannel: Received status code ${response.statusCode}, success: ${responseData['success']}"); // Added debug print
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to join channel');
    }
  }

  Future<Map<String, dynamic>> partChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/part');
    print("[ApiService] partChannel: Calling POST $url for channel $channelName"); // Added debug print
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );
    final responseData = json.decode(response.body);
    print("[ApiService] partChannel: Received status code ${response.statusCode}, success: ${responseData['success']}"); // Added debug print
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to part channel');
    }
  }

  // New method to upload avatar
  Future<Map<String, dynamic>> uploadAvatar(File imageFile, String token) async {
    final uri = Uri.parse('$baseUrl/upload-avatar');
    print("[ApiService] uploadAvatar: Calling POST $uri for avatar upload."); // Added debug print
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'; // Use the passed token directly

    // Determine the content type based on the file extension
    String? mimeType;
    final String fileExtension = imageFile.path.split('.').last.toLowerCase();
    switch (fileExtension) {
      case 'jpg':
      case 'jpeg':
        mimeType = 'image/jpeg';
        break;
      case 'png':
      case 'gif':
        mimeType = 'image/png';
        break;
      default:
        mimeType = 'application/octet-stream'; // Fallback for unknown types
    }

    request.files.add(
      await http.MultipartFile.fromPath(
        'avatar', // This must match the field name in the Go handler (c.FormFile("avatar"))
        imageFile.path,
        contentType: mimeType != null ? MediaType.parse(mimeType) : null,
      ),
    );

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode == 200) {
      print("[ApiService] uploadAvatar: Upload successful, status 200."); // Added debug print
      return json.decode(responseBody);
    } else {
      print("[ApiService] uploadAvatar: Upload failed, status ${response.statusCode}, body: $responseBody"); // Added debug print
      final errorData = json.decode(responseBody);
      throw Exception('Failed to upload avatar: ${response.statusCode} - ${errorData['message'] ?? responseBody}');
    }
  }
}