import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../config.dart';
import '../models/login_response.dart';
import '../models/channel.dart'; // Use Message and Channel from here
import '../main.dart';

import '../models/irc_network.dart'; // Import the new IrcNetwork model

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

  /// Always call this after login and before any authenticated API/WebSocket use.
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
    print("[ApiService] login: Calling POST $url for $username");
    try {
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );
      // print("[ApiService] login: Received status code ${response.statusCode}");

      if (response.statusCode != 200) {
        // Decode response to get the specific message from the backend
        final errorData = json.decode(response.body);
        return LoginResponse(
            success: false,
            message: errorData['message'] ??
                'Login failed. Please check your credentials.');
      }

      final responseData = json.decode(response.body);
      return LoginResponse.fromJson(responseData);
    } catch (e) {
      print("[ApiService] login Error: $e");
      return LoginResponse(
          success: false, message: 'Network error during login: $e');
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
      print(
          "[ApiService] registerFCMToken: Failed with status ${response.statusCode}, body: ${response.body}");
      // Optionally throw a different exception for other errors
    }
  }

  @Deprecated('Use fetchIrcNetworks to get network-specific channels.')
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
      // Note: This won't have network_id directly unless the backend adds it to this endpoint.
      // As per server code, it returns list of channels from all networks.
      // The `Channel.fromJson` expects network_id, so this might break or return 0.
      // This method should probably be removed entirely if fetchIrcNetworks is the primary way.
      // For now, mapping it with a dummy networkId to allow compilation.
      return apiChannels.map((c) => Channel.fromJson({...c, 'network_id': 0})).toList();
    } else {
      throw Exception(data['message'] ?? "Failed to load channels");
    }
  }

  /// Fetches the list of IRC networks configured for the current user.
  Future<List<IrcNetwork>> fetchIrcNetworks() async {
    final url = Uri.parse('$baseUrl/irc/networks');
    print("[ApiService] fetchIrcNetworks: Calling GET $url");
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      _handleResponseError(response);

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> apiNetworks = data['networks'] ?? [];
        print(
            "[ApiService] fetchIrcNetworks: Received ${apiNetworks.length} networks.");
        return apiNetworks.map((n) => IrcNetwork.fromJson(n)).toList();
      } else {
        throw Exception(data['message'] ?? "Failed to load IRC networks");
      }
    } catch (e) {
      print("[ApiService] fetchIrcNetworks Error: $e");
      rethrow;
    }
  }

  /// Fetches a single IRC network's details by ID.
  Future<IrcNetwork> fetchIrcNetworkDetails(int networkId) async {
    final url = Uri.parse('$baseUrl/irc/networks/$networkId'); // Use the new endpoint
    print("[ApiService] fetchIrcNetworkDetails: Calling GET $url for ID $networkId");
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      _handleResponseError(response);

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true && data.containsKey('network')) {
        final Map<String, dynamic> apiNetwork = data['network'] as Map<String, dynamic>;
        print("[ApiService] fetchIrcNetworkDetails: Successfully fetched network details for ID $networkId.");
        return IrcNetwork.fromJson(apiNetwork);
      } else {
        throw Exception(data['message'] ?? "Failed to load IRC network details");
      }
    } catch (e) {
      print("[ApiService] fetchIrcNetworkDetails Error: $e");
      rethrow;
    }
  }

  /// Adds a new IRC network configuration.
  Future<Map<String, dynamic>> addIrcNetwork(IrcNetwork network) async {
    final url = Uri.parse('$baseUrl/irc/networks');
    print("[ApiService] addIrcNetwork: Calling POST $url for ${network.networkName}");
    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_getToken()}',
        },
        body: json.encode(network.toJson()),
      );

      _handleResponseError(response);

      final responseData = json.decode(response.body);
      // --- FIX: Support new server-side response format ---
      if (response.statusCode == 201 && responseData['success'] == true) {
        if (responseData.containsKey('network')) {
          print(
              "[ApiService] addIrcNetwork: Success, network ID: ${responseData['network']['id']}");
        } else if (responseData.containsKey('network_id')) {
          print(
              "[ApiService] addIrcNetwork: Success, network ID: ${responseData['network_id']}");
        }
        return responseData;
      } else {
        throw Exception(responseData['message'] ?? "Failed to add network");
      }
    } catch (e) {
      print("[ApiService] addIrcNetwork Error: $e");
      rethrow;
    }
  }

  /// Updates an existing IRC network configuration.
  Future<Map<String, dynamic>> updateIrcNetwork(IrcNetwork network) async {
    final url = Uri.parse('$baseUrl/irc/networks/${network.id}');
    print(
        "[ApiService] updateIrcNetwork: Calling PUT $url for ${network.networkName}");
    try {
      final response = await http.put(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${_getToken()}',
        },
        body: json.encode(network.toJson(includeId: true)),
      );

      _handleResponseError(response);

      final responseData = json.decode(response.body);
      if (response.statusCode == 200 && responseData['success'] == true) {
        print("[ApiService] updateIrcNetwork: Success");
        return responseData;
      } else {
        throw Exception(responseData['message'] ?? "Failed to update network");
      }
    } catch (e) {
      print("[ApiService] updateIrcNetwork Error: $e");
      rethrow;
    }
  }

  /// Deletes an IRC network configuration.
  Future<Map<String, dynamic>> deleteIrcNetwork(int networkId) async {
    final url = Uri.parse('$baseUrl/irc/networks/$networkId');
    print("[ApiService] deleteIrcNetwork: Calling DELETE $url for ID $networkId");
    try {
      final response = await http.delete(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      _handleResponseError(response);

      final responseData = json.decode(response.body);
      if (response.statusCode == 200 && responseData['success'] == true) {
        print("[ApiService] deleteIrcNetwork: Success");
        return responseData;
      } else {
        throw Exception(responseData['message'] ?? "Failed to delete network");
      }
    } catch (e) {
      print("[ApiService] deleteIrcNetwork Error: $e");
      rethrow;
    }
  }

  /// Manually connects to an IRC network.
  Future<Map<String, dynamic>> connectIrcNetwork(int networkId) async {
    final url = Uri.parse('$baseUrl/irc/networks/$networkId/connect');
    print("[ApiService] connectIrcNetwork: Calling POST $url for ID $networkId");
    try {
      final response = await http.post(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      _handleResponseError(response);

      final responseData = json.decode(response.body);
      if (response.statusCode == 200 && responseData['success'] == true) {
        print("[ApiService] connectIrcNetwork: Success");
        return responseData;
      } else {
        throw Exception(
            responseData['message'] ?? "Failed to connect to network");
      }
    } catch (e) {
      print("[ApiService] connectIrcNetwork Error: $e");
      rethrow;
    }
  }

  /// Manually disconnects from an IRC network.
  Future<Map<String, dynamic>> disconnectIrcNetwork(int networkId) async {
    final url = Uri.parse('$baseUrl/irc/networks/$networkId/disconnect');
    print(
        "[ApiService] disconnectIrcNetwork: Calling POST $url for ID $networkId");
    try {
      final response = await http.post(
        url,
        headers: {'Authorization': 'Bearer ${_getToken()}'},
      );

      _handleResponseError(response);

      final responseData = json.decode(response.body);
      if (response.statusCode == 200 && responseData['success'] == true) {
        print("[ApiService] disconnectIrcNetwork: Success");
        return responseData;
      } else {
        throw Exception(
            responseData['message'] ?? "Failed to disconnect from network");
      }
    } catch (e) {
      print("[ApiService] disconnectIrcNetwork Error: $e");
      rethrow;
    }
  }

  // Updated to include networkId in the URL path and return List<Message>
  Future<List<Message>> fetchChannelMessages(
      int networkId, String channelName, {int limit = 2500}) async {
    print("[ApiService] fetchChannelMessages: Attempting to fetch history for network $networkId, channel $channelName");
    if (channelName.isEmpty) {
      print("[ApiService] fetchChannelMessages: Channel name is empty, returning empty list.");
      return [];
    }

    final encodedChannelName = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$networkId/$encodedChannelName?limit=$limit'); // Updated URL
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
      print("[ApiService] fetchChannelMessages: Successfully fetched ${history.length} messages for network $networkId, channel $channelName");
      // Map to Message objects directly
      return history.map<Message>((msg) => Message.fromJson({
        'network_id': msg['network_id'] ?? networkId, // Ensure network_id is included
        'sender': msg['sender'] ?? 'Unknown',
        'text': msg['text'] ?? '',
        'timestamp': msg['timestamp'] ?? DateTime.now().toIso8601String(),
        'id': msg['id'] ?? 'hist-${msg['timestamp']}-${msg['sender']}',
        'isHistorical': true, // Mark as historical
        'channel_name': msg['channel'] ?? channelName, // Use 'channel' from backend if available, else local channelName
      })).toList();
    } else {
      print("[ApiService] fetchChannelMessages: API returned non-200 status for $channelName: ${response.statusCode}");
      throw Exception("Failed to load messages: Status ${response.statusCode}, Body: ${response.body}");
    }
  }

  // Updated to include networkId in the URL path and return List<Message>
  Future<List<Message>> fetchMessagesSince(
      int networkId, String channelName, DateTime since) async {
    final encodedChannel = Uri.encodeComponent(channelName);
    final url = Uri.parse('$baseUrl/history/$networkId/$encodedChannel?since=${since.toIso8601String()}'); // Updated URL
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
      print("[ApiService] fetchMessagesSince: Successfully fetched ${history.length} missed messages for network $networkId, channel $channelName since $since");
      return history.map<Message>((msg) => Message.fromJson({
        'network_id': msg['network_id'] ?? networkId, // Ensure network_id is included
        'sender': msg['sender'] ?? 'Unknown',
        'text': msg['text'] ?? '',
        'timestamp': msg['timestamp'] ?? DateTime.now().toIso8601String(),
        'id': (msg['id'] ?? DateTime.now().millisecondsSinceEpoch).toString(),
        'isHistorical': true, // Mark as historical
        'channel_name': msg['channel'] ?? channelName,
      })).toList();
    } else {
      print("[ApiService] fetchMessagesSince: API returned non-200 status for $channelName: ${response.statusCode}");
      throw Exception("Failed to load missed messages: Status ${response.statusCode}, Body: ${response.body}");
    }
  }

  // Updated to include networkId in the request body
  Future<Map<String, dynamic>> joinChannel(int networkId, String channelName) async {
    final url = Uri.parse('$baseUrl/channels/join');
    print("[ApiService] joinChannel: Calling POST $url for network $networkId channel $channelName");
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'network_id': networkId, 'channel': channelName}), // Updated body
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

  // Updated to include networkId in the request body
  Future<Map<String, dynamic>> partChannel(int networkId, String channelName) async {
    final url = Uri.parse('$baseUrl/channels/part');
    print("[ApiService] partChannel: Calling POST $url for network $networkId channel $channelName");
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${_getToken()}',
      },
      body: json.encode({'network_id': networkId, 'channel': channelName}), // Updated body
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

  /// Returns true if the session is still valid, false otherwise.
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