import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config.dart';
import '../models/login_response.dart';
import '../models/channel.dart'; // Use Message and Channel from here
import '../main.dart';

class ApiService {
  String? _token;

  ApiService([this._token]);

  void setToken(String token) {
    _token = token;
  }

  bool _checkForTokenInvalidation(http.Response response) {
    if (response.statusCode == 401) {
      AuthWrapper.forceLogout(showExpiredMessage: true);
      return true;
    }
    return false;
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
      throw Exception("Authentication token is not set for ApiService.");
    }
    return _token!;
  }

  Future<void> registerFCMToken(String fcmToken) async {
    final url = Uri.parse('$baseUrl/register-fcm-token');
    print("[ApiService] registerFCMToken: Calling POST $url");
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_getToken()}',
        },
        body: json.encode({'fcm_token': fcmToken}),
      );
      if (_checkForTokenInvalidation(response)) {
        print("[ApiService] registerFCMToken: Token invalid, force logout.");
        return;
      }
      if (response.statusCode == 200) {
        print("[ApiService] registerFCMToken: Success");
      } else {
        print("[ApiService] registerFCMToken: Failed with status ${response.statusCode}, body: ${response.body}");
      }
    } catch (e) {
      print("[ApiService] registerFCMToken Error: $e");
    }
  }

  Future<List<Channel>> fetchChannels() async {
    final url = Uri.parse('$baseUrl/channels');
    print("[ApiService] fetchChannels: Calling GET $url with token: $_token");
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      if (_checkForTokenInvalidation(response)) {
        throw Exception("Session expired");
      }

      print("[ApiService] fetchChannels: Received status code ${response.statusCode}");

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> apiChannels = data['channels'] ?? [];
        return apiChannels.map((c) => Channel.fromJson(c)).toList();
      } else {
        throw Exception(data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      print("[ApiService] fetchChannels Error: $e");
      throw Exception("Network error fetching channels: $e");
    }
  }

  Future<List<Map<String, dynamic>>> fetchChannelMessages(String channelName, {int limit = 100}) async {
    print("[ApiService] fetchChannelMessages: Attempting to fetch history for $channelName");
    if (channelName.isEmpty) {
      print("[ApiService] fetchChannelMessages: Channel name is empty, returning empty list.");
      return [];
    }

    final encodedChannelName = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$encodedChannelName?limit=$limit');
    final token = _getToken();
    print("[ApiService] fetchChannelMessages: Calling GET $url");

    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (_checkForTokenInvalidation(response)) {
        throw Exception("Session expired");
      }

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
    } catch (e) {
      print("[ApiService] fetchChannelMessages Error for $channelName: $e");
      throw Exception("Network error fetching messages: $e");
    }
  }

  Future<List<Message>> fetchMessagesSince(String channelName, DateTime since) async {
    final encodedChannel = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$encodedChannel?since=${since.toIso8601String()}');
    final token = _getToken();
    print("[ApiService] fetchMessagesSince: Calling GET $url");
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (_checkForTokenInvalidation(response)) {
        throw Exception("Session expired");
      }

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
    } catch (e) {
      print("[ApiService] fetchMessagesSince Error for $channelName: $e");
      throw Exception("Network error fetching missed messages: $e");
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

    if (_checkForTokenInvalidation(response)) {
      throw Exception("Session expired");
    }

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

    if (_checkForTokenInvalidation(response)) {
      throw Exception("Session expired");
    }

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

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode == 401) {
      AuthWrapper.forceLogout(showExpiredMessage: true);
      throw Exception('Session expired');
    }

    if (response.statusCode == 200) {
      print("[ApiService] uploadAvatar: Upload successful, status 200.");
      return json.decode(responseBody);
    } else {
      print("[ApiService] uploadAvatar: Upload failed, status ${response.statusCode}, body: $responseBody");
      final errorData = json.decode(responseBody);
      throw Exception('Failed to upload avatar: ${response.statusCode} - ${errorData['message'] ?? responseBody}');
    }
  }
}