import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../main.dart'; // Import AuthWrapper from main.dart

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

  final StreamController<String> _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  WebSocketService() {
    _statusController.stream.listen((status) {
      _currentWsStatus = status;
    });
  }

  void connect(String token) {
    if (_ws != null && _currentWsStatus == WebSocketStatus.connected) {
      print("[WebSocketService] Already connected.");
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
      }).catchError((e) {
        print("[WebSocketService] Initial connection error: $e");
        if (_isUnauthorized(e.toString())) {
          _handleUnauthorized();
        } else {
          _handleWebSocketError(e);
        }
      });

      _ws!.stream.listen((message) {
        final event = jsonDecode(message);
        print("[WebSocketService] Received event: $event");

        if (event['type'] == 'initial_state') {
          final List<dynamic> receivedChannels = event['payload']['channels'] ?? [];
          _currentChannels = receivedChannels.map((c) => c['name'].toString()).toList();
          _channelsController.add(List.from(_currentChannels));
        } else if (event['type'] == 'channel_join') {
          final String channelName = event['payload']['name'];
          if (!_currentChannels.contains(channelName)) {
            _currentChannels.add(channelName);
            _currentChannels.sort();
            _channelsController.add(List.from(_currentChannels));
          }
        } else if (event['type'] == 'channel_part') {
          final String channelName = event['payload']['name'];
          if (_currentChannels.remove(channelName)) {
            _channelsController.add(List.from(_currentChannels));
          }
        } else if (event['type'] == 'message') {
          _messageController.add({
            'channel_name': event['payload']['channel_name'],
            'sender': event['payload']['sender'],
            'text': event['payload']['text'],
            'time': event['payload']['time'] ?? DateTime.now().toIso8601String(),
          });
        }
      }, onError: (e) {
        print("[WebSocketService] Error occurred: $e");
        if (_isUnauthorized(e.toString())) {
          _handleUnauthorized();
        } else {
          _handleWebSocketError(e);
        }
      }, onDone: _handleWebSocketDone);
    } catch (e) {
      print("[WebSocketService] Connection setup failed: $e");
      _handleWebSocketError(e);
    }
  }

  void _handleUnauthorized() {
    print("[WebSocketService] Unauthorized token — force logout.");
    _statusController.add(WebSocketStatus.unauthorized);
    disconnect();
    AuthWrapper.forceLogout(); // Call static method to trigger logout
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
    return error.contains('401') ||
           error.contains('unauthorized') ||
           error.contains('not upgraded to websocket');
  }

  void sendMessage(String channelName, String text) {
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      _errorController.add("Cannot send message: WebSocket not connected.");
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
    _errorController.close();
  }
}