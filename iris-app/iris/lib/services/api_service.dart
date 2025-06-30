import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config.dart';
import '../models/login_response.dart';
import '../models/channel.dart'; // Use Message and Channel from here
import '../main.dart';

// Define the custom exception class here for better organization
class SessionExpiredException implements Exception {
  final String message;
  SessionExpiredException([this.message = "Your session has expired. Please log in again."]);

  @override
  String toString() => message;
}


class ApiService {
  String? _token;

  ApiService([this._token]);

  void setToken(String token) {
    _token = token;
  }

  // This centralized method checks for a 401 and throws our custom exception.
  void _handleResponseError(http.Response response) {
    if (response.statusCode == 401) {
      throw SessionExpiredException();
    }
  }

  Future<LoginResponse> login(String username, String password) async {
    final url = Uri.parse('$baseUrl/login');
    print("[ApiService] login: Calling POST $url");
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );
      print("[ApiService] login: Received status code ${response.statusCode}");

      if (response.statusCode == 401) {
        return LoginResponse(success: false, message: 'Invalid username or password.');
      }

      if (response.statusCode != 200) {
        return LoginResponse(success: false, message: 'Server error. Please try again later.');
      }

      final responseData = json.decode(response.body);
      return LoginResponse.fromJson(responseData);
    } catch (e) {
      print("[ApiService] login Error: $e");
      return LoginResponse(success: false, message: 'Network error during login: $e');
    }
  }

  String _getToken() {
    if (_token == null) {
      // Throwing an exception here is better for debugging than a silent failure.
      throw Exception("Authentication token is not set for ApiService.");
    }
    return _token!;
  }

  Future<void> registerFCMToken(String fcmToken) async {
    final url = Uri.parse('$baseUrl/register-fcm-token');
    print("[ApiService] registerFCMToken: Calling POST $url");

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'fcm_token': fcmToken}),
    );

    _handleResponseError(response); // Check for 401

    if (response.statusCode == 200) {
      print("[ApiService] registerFCMToken: Success");
    } else {
      print("[ApiService] registerFCMToken: Failed with status ${response.statusCode}, body: ${response.body}");
      // Optionally throw a different exception for other errors
    }
  }

  Future<List<Channel>> fetchChannels() async {
    final url = Uri.parse('$baseUrl/channels');
    print("[ApiService] fetchChannels: Calling GET $url");

    final response = await http.get(
      url,
      headers: {'Authorization': 'Bearer ${_getToken()}'},
    );

    _handleResponseError(response); // Check for 401

    print("[ApiService] fetchChannels: Received status code ${response.statusCode}");

    final data = jsonDecode(response.body);
    if (response.statusCode == 200 && data['success'] == true) {
      final List<dynamic> apiChannels = data['channels'] ?? [];
      return apiChannels.map((c) => Channel.fromJson(c)).toList();
    } else {
      throw Exception(data['message'] ?? "Failed to load channels");
    }
  }

  Future<List<Map<String, dynamic>>> fetchChannelMessages(String channelName, {int limit = 2500}) async {
    print("[ApiService] fetchChannelMessages: Attempting to fetch history for $channelName");
    if (channelName.isEmpty) {
      print("[ApiService] fetchChannelMessages: Channel name is empty, returning empty list.");
      return [];
    }

    final encodedChannelName = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$encodedChannelName?limit=$limit');
    print("[ApiService] fetchChannelMessages: Calling GET $url");

    final response = await http.get(
      url,
      headers: {'Authorization': 'Bearer ${_getToken()}'},
    );

    _handleResponseError(response); // Check for 401

    print("[ApiService] fetchChannelMessages: Received status code ${response.statusCode} for $channelName");

    final data = jsonDecode(response.body);

    if (response.statusCode == 200 && data['success'] == true) {
      final List<dynamic> history = data['history'] ?? [];
      print("[ApiService] fetchChannelMessages: Successfully fetched ${history.length} messages for $channelName");
      return history.map((msg) => {
        'from': msg['sender'] ?? 'Unknown',
        'content': msg['text'] ?? '',
        'time': msg['timestamp'] ?? DateTime.now().toIso8601String(),
        'id': msg['id'] ?? 'hist-${msg['timestamp']}-${msg['sender']}',
      }).toList();
    } else {
      print("[ApiService] fetchChannelMessages: API returned non-200 status for $channelName: ${response.statusCode}");
      throw Exception("Failed to load messages: Status ${response.statusCode}, Body: ${response.body}");
    }
  }

  Future<List<Message>> fetchMessagesSince(String channelName, DateTime since) async {
    final encodedChannel = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$encodedChannel?since=${since.toIso8601String()}');
    print("[ApiService] fetchMessagesSince: Calling GET $url");

    final response = await http.get(
      url,
      headers: {'Authorization': 'Bearer ${_getToken()}'},
    );

    _handleResponseError(response); // Check for 401

    print("[ApiService] fetchMessagesSince: Received status code ${response.statusCode} for $channelName");

    final data = jsonDecode(response.body);

    if (response.statusCode == 200 && data['success'] == true) {
      final List<dynamic> history = data['history'] ?? [];
      print("[ApiService] fetchMessagesSince: Successfully fetched ${history.length} missed messages for $channelName since $since");
      return history.map<Message>((msg) => Message(
        from: msg['sender'] ?? 'Unknown',
        content: msg['text'] ?? '',
        time: DateTime.tryParse(msg['timestamp'] ?? '')?.toLocal() ?? DateTime.now(),
        id: (msg['id'] ?? DateTime.now().millisecondsSinceEpoch).toString(),
        isHistorical: true,
      )).toList();
    } else {
      print("[ApiService] fetchMessagesSince: API returned non-200 status for $channelName: ${response.statusCode}");
      throw Exception("Failed to load missed messages: Status ${response.statusCode}, Body: ${response.body}");
    }
  }

  Future<Map<String, dynamic>> joinChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/join');
    print("[ApiService] joinChannel: Calling POST $url for channel $channelName");
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );

    _handleResponseError(response); // Check for 401

    final responseData = json.decode(response.body);
    print("[ApiService] joinChannel: Received status code ${response.statusCode}, success: ${responseData['success']}");
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to join channel');
    }
  }

  Future<Map<String, dynamic>> partChannel(String channelName) async {
    final url = Uri.parse('$baseUrl/channels/part');
    print("[ApiService] partChannel: Calling POST $url for channel $channelName");
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'channel': channelName}),
    );

    _handleResponseError(response); // Check for 401

    final responseData = json.decode(response.body);
    print("[ApiService] partChannel: Received status code ${response.statusCode}, success: ${responseData['success']}");
    if (response.statusCode == 200 && responseData['success'] == true) {
      return responseData;
    } else {
      throw Exception(responseData['message'] ?? 'Failed to part channel');
    }
  }

  Future<Map<String, dynamic>> uploadAvatar(File imageFile, String token) async {
    final uri = Uri.parse('$baseUrl/upload-avatar');
    print("[ApiService] uploadAvatar: Calling POST $uri for avatar upload.");
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token';

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
        mimeType = 'application/octet-stream';
    }

    request.files.add(
      await http.MultipartFile.fromPath(
        'avatar',
        imageFile.path,
        contentType: mimeType != null ? MediaType.parse(mimeType) : null,
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    _handleResponseError(response); // Check for 401

    final responseBody = response.body;
    if (response.statusCode == 200) {
      print("[ApiService] uploadAvatar: Upload successful, status 200.");
      return json.decode(responseBody);
    } else {
      print("[ApiService] uploadAvatar: Upload failed, status ${response.statusCode}, body: $responseBody");
      final errorData = json.decode(responseBody);
      throw Exception('Failed to upload avatar: ${response.statusCode} - ${errorData['message'] ?? responseBody}');
    }
  }

  Future<String?> uploadAttachmentAndGetUrl(File file) async {
    final uri = Uri.parse('$baseUrl/upload-attachment');
    print("[ApiService] uploadAttachmentAndGetUrl: Uploading attachment to $uri");
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_getToken()}';
    String? mimeType;
    final String fileExtension = file.path.split('.').last.toLowerCase();
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
        mimeType = 'application/octet-stream';
    }
    request.files.add(
      await http.MultipartFile.fromPath(
        'attachment',
        file.path,
        contentType: mimeType != null ? MediaType.parse(mimeType) : null,
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    _handleResponseError(response); // Check for 401

    final responseBody = response.body;
    if (response.statusCode == 200) {
      print("[ApiService] uploadAttachmentAndGetUrl: Success, status 200.");
      final data = json.decode(responseBody);
      return '$baseSecureUrl${data['url']}';
    } else {
      print("[ApiService] uploadAttachmentAndGetUrl: Upload failed, status ${response.statusCode}, body: $responseBody");
      final errorData = json.decode(responseBody);
      throw Exception('Failed to upload attachment: ${response.statusCode} - ${errorData['message'] ?? responseBody}');
    }
  }

  Future<bool> validateSession() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/validate-session'),
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );
      // We only care about success (200) vs fail (anything else)
      return response.statusCode == 200;
    } catch (e) {
      // Catching network errors etc. should also count as a validation failure.
      return false;
    }
  }
}