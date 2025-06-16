import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

class ApiService {
  final String _token;

  ApiService(this._token);

  /// Fetches the list of channels from the API.
  Future<List<String>> fetchChannels() async {
    final url = Uri.parse('$baseUrl/channels');
    try {
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $_token'},
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
        headers: {'Authorization': 'Bearer $_token'},
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
}
