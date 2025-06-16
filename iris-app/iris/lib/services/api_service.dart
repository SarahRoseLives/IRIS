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
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );

      // Always try to parse the response with LoginResponse.fromJson
      final responseData = json.decode(response.body);
      return LoginResponse.fromJson(responseData);
    } catch (e) {
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
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> apiChannels = data['channels'] ?? [];
        return apiChannels.map((c) => c['name'].toString()).toList();
      } else {
        throw Exception(data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      throw Exception("Network error fetching channels: $e");
    }
  }

  /// Fetches messages for a specific channel from the API.
  Future<List<Map<String, dynamic>>> fetchChannelMessages(String channelName) async {
    if (channelName.isEmpty) return [];

    final url = Uri.parse('$baseUrl/channels/$channelName/messages');
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> receivedMessages = data['messages'] ?? [];
        return receivedMessages.map((msg) => {
              'from': msg['from'] ?? '',
              'content': msg['content'] ?? '',
              'time': msg['time'] ?? DateTime.now().toIso8601String(),
            }).toList();
      } else {
        throw Exception("Failed to load messages: ${data['message'] ?? response.statusCode}");
      }
    } catch (e) {
      throw Exception("Network error fetching messages: $e");
    }
  }

  Future<Map<String, dynamic>> joinChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/join');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );
    final responseData = json.decode(response.body);
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to join channel');
    }
  }

  Future<Map<String, dynamic>> partChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/part');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );
    final responseData = json.decode(response.body);
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to part channel');
    }
  }

  // New method to upload avatar
  Future<Map<String, dynamic>> uploadAvatar(File imageFile, String token) async {
    final uri = Uri.parse('$baseUrl/upload-avatar');
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
        mimeType = 'image/png';
        break;
      case 'gif':
        mimeType = 'image/gif';
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
      return json.decode(responseBody);
    } else {
      // Provide more detailed error information
      final errorData = json.decode(responseBody);
      throw Exception('Failed to upload avatar: ${response.statusCode} - ${errorData['message'] ?? responseBody}');
    }
  }
}