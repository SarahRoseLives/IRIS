import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../main.dart';
import '../models/channel_member.dart';

enum WebSocketStatus {
  disconnected,
  connecting,
  connected,
  error,
  unauthorized,
}

class WebSocketService {
  WebSocketChannel? _ws;
  String? _token;
  Timer? _reconnectTimer;

  WebSocketStatus _currentWsStatus = WebSocketStatus.disconnected;
  List<String> _currentChannels = [];

  final StreamController<WebSocketStatus> _statusController = StreamController<WebSocketStatus>.broadcast();
  Stream<WebSocketStatus> get statusStream => _statusController.stream;

  final StreamController<List<String>> _channelsController = StreamController<List<String>>.broadcast();
  Stream<List<String>> get channelsStream => _channelsController.stream;

  final StreamController<Map<String, dynamic>> _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<Map<String, dynamic>> _membersUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get membersUpdateStream => _membersUpdateController.stream;

  final StreamController<Map<String, dynamic>> _initialStateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get initialStateStream => _initialStateController.stream;

  final StreamController<String> _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  WebSocketService() {
    _statusController.stream.listen((status) {
      _currentWsStatus = status;
    });
  }

  /// Public setter for updating the currently tracked channels from outside.
  void updateCurrentChannels(List<String> channels) {
    _currentChannels = channels;
  }

  void connect(String token) {
    if (_ws != null && _currentWsStatus == WebSocketStatus.connected) {
      print("[WebSocketService] Already connected. Skipping new connection attempt.");
      return;
    }

    _reconnectTimer?.cancel();
    _token = token;
    _statusController.add(WebSocketStatus.connecting);
    print("[WebSocketService] Attempting to connect...");

    final uri = Uri.parse("$websocketUrl/$token");

    try {
      _ws = WebSocketChannel.connect(uri);
      _ws!.ready.then((_) {
        _statusController.add(WebSocketStatus.connected);
        print("[WebSocketService] Connected successfully to: $uri");

        // Send current channels to restore state (fix)
        _ws!.sink.add(jsonEncode({
          'type': 'restore_state',
          'payload': {
            'channels': _currentChannels,
          }
        }));
      }).catchError((e) {
        print("[WebSocketService] Initial connection error: $e");
        if (_isUnauthorized(e.toString())) {
          _handleUnauthorized();
        } else {
          _handleWebSocketError(e);
        }
      });

      _ws!.stream.listen((message) {
        print("[WebSocketService] Raw message received: $message");

        Map<String, dynamic> event;
        try {
          event = jsonDecode(message);
        } catch (e) {
          print("[WebSocketService] Error decoding JSON: $e, Raw message: $message");
          _errorController.add("WebSocket JSON parsing error: $e");
          return;
        }

        print("[WebSocketService] Parsed event: $event (Type: ${event['type']})");
        final payload = event['payload'];

        switch (event['type']) {
          case 'restore_state':
            if (payload is Map<String, dynamic>) {
              final channels = payload['channels'] as List<dynamic>? ?? [];
              _currentChannels = List<String>.from(channels);
              _channelsController.add(List.from(_currentChannels));
              print("[WebSocketService] Updated channels from restore_state: $_currentChannels");
            }
            break;
          case 'initial_state':
            if (payload is Map<String, dynamic>) {
              final channels = payload['channels'] as Map<String, dynamic>? ?? {};
              final users = payload['users'] as Map<String, dynamic>? ?? {};
              _initialStateController.add({
                'channels': channels,
                'users': users,
              });
              print("[WebSocketService] Forwarded initial state payload with ${channels.keys.length} channels and ${users.keys.length} users.");
            }
            break;
          case 'channel_join':
            final String channelName = payload['name'];
            if (!_currentChannels.contains(channelName)) {
              _currentChannels.add(channelName);
              _currentChannels.sort();
              _channelsController.add(List.from(_currentChannels));
            }
            print("[WebSocketService] Added joined channel to stream: $channelName");
            break;
          case 'channel_part':
            final String channelName = payload['name'];
            if (_currentChannels.remove(channelName)) {
              _channelsController.add(List.from(_currentChannels));
            }
            print("[WebSocketService] Removed parted channel from stream: $channelName");
            break;
          case 'message':
            _messageController.add({
              'channel_name': payload['channel_name'],
              'sender': payload['sender'],
              'text': payload['text'],
              'time': payload['time'] ?? DateTime.now().toIso8601String(),
            });
            print("[WebSocketService] ADDED MESSAGE TO STREAM: ${payload['text']}");
            break;
          case 'history_message':
            _messageController.add({
              'channel_name': payload['channel_name'],
              'sender': payload['sender'],
              'text': payload['text'],
              'time': payload['timestamp'] ?? DateTime.now().toIso8601String(),
              'is_history': true,
            });
            print("[WebSocketService] ADDED HISTORY MESSAGE TO STREAM: ${payload['text']}");
            break;
          case 'members_update':
            final String channelName = payload['channel_name'];
            final List<dynamic> membersData = payload['members'] ?? [];
            final List<ChannelMember> members = membersData.map((m) => ChannelMember.fromJson(m)).toList();
            _membersUpdateController.add({'channel_name': channelName, 'members': members});
            print("[WebSocketService] Received members update for $channelName");
            break;
        }
      }, onError: (e) {
        print("[WebSocketService] Stream listener error: $e");
        if (_isUnauthorized(e.toString())) {
          _handleUnauthorized();
        } else {
          _handleWebSocketError(e);
        }
      }, onDone: _handleWebSocketDone);
    } catch (e) {
      print("[WebSocketService] Outer catch: Connection setup failed: $e");
      _handleWebSocketError(e);
    }
  }

  void _handleUnauthorized() {
    print("[WebSocketService] Unauthorized token — force logout.");
    _statusController.add(WebSocketStatus.unauthorized);
    disconnect();
    AuthWrapper.forceLogout();
  }

  void _handleWebSocketError(dynamic error) {
    _errorController.add("WebSocket Error: $error");
    _statusController.add(WebSocketStatus.error);
    _scheduleReconnect();
  }

  void _handleWebSocketDone() {
    print("[WebSocketService] Connection closed.");
    if (_currentWsStatus != WebSocketStatus.unauthorized) {
      _statusController.add(WebSocketStatus.disconnected);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_token != null &&
          _currentWsStatus != WebSocketStatus.connecting &&
          _currentWsStatus != WebSocketStatus.connected &&
          _currentWsStatus != WebSocketStatus.unauthorized) {
        print("[WebSocketService] Attempting to reconnect...");
        connect(_token!);
      }
    });
  }

  bool _isUnauthorized(String error) {
    return error.contains('401') || error.contains('unauthorized') || error.contains('not upgraded to websocket');
  }

  void sendMessage(String channelName, String text) {
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      _errorController.add("Cannot send message: WebSocket not connected.");
      print("[WebSocketService] Cannot send message: WS not connected.");
      return;
    }
    final messageToSend = jsonEncode({
      'type': 'message',
      'payload': {
        'channel_name': channelName,
        'text': text,
      },
    });
    _ws?.sink.add(messageToSend);
    print("[WebSocketService] Sent message: $messageToSend");
  }

  /// Send a history request for a channel in JSON format (recommended).
  void sendHistoryRequest(String channelName, String duration) {
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      _errorController.add("Cannot send history request: WebSocket not connected.");
      print("[WebSocketService] Cannot send history request: WS not connected.");
      return;
    }
    final historyReq = jsonEncode({
      'type': 'history',
      'payload': {
        'channel_name': channelName,
        'duration': duration,
      },
    });
    _ws?.sink.add(historyReq);
    print("[WebSocketService] Sent history request: $historyReq");
  }

  /// Deprecated: Use sendHistoryRequest for commands; only use for literal text if server expects it.
  void sendRawMessage(String message) {
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      _errorController.add("Cannot send raw message: WebSocket not connected.");
      print("[WebSocketService] Cannot send raw message: WS not connected.");
      return;
    }
    _ws?.sink.add(message);
    print("[WebSocketService] Sent raw message: $message");
  }

  void disconnect() {
    _ws?.sink.close();
    _reconnectTimer?.cancel();
    _statusController.add(WebSocketStatus.disconnected);
    print("[WebSocketService] Disconnected.");
  }

  void dispose() {
    disconnect();
    _statusController.close();
    _channelsController.close();
    _messageController.close();
    _membersUpdateController.close();
    _initialStateController.close();
    _errorController.close();
  }
}