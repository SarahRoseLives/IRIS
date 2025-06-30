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

  bool _isDisposed = false;

  final _statusController = StreamController<WebSocketStatus>.broadcast();
  Stream<WebSocketStatus> get statusStream => _statusController.stream;

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final _membersUpdateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get membersUpdateStream =>
      _membersUpdateController.stream;

  final _initialStateController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get initialStateStream =>
      _initialStateController.stream;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  WebSocketService() {
    _statusController.stream.listen((status) {
      _currentWsStatus = status;
    });
  }

  void connect(String token) {
    if (_isDisposed) return;
    if (_currentWsStatus == WebSocketStatus.connected ||
        _currentWsStatus == WebSocketStatus.connecting) {
      print(
          "[WebSocketService] Already connected or connecting. Skipping new connection attempt.");
      return;
    }

    _reconnectTimer?.cancel();
    _token = token;
    if (!_isDisposed) _statusController.add(WebSocketStatus.connecting);
    print("[WebSocketService] Attempting to connect...");

    final uri = Uri.parse("$websocketUrl/$token");
    try {
      _ws = WebSocketChannel.connect(uri);

      _ws!.ready.then((_) {
        if (!_isDisposed) _statusController.add(WebSocketStatus.connected);
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
        if (_isDisposed) return;
        print("[WebSocketService] Raw message received: $message");

        Map<String, dynamic> event;
        try {
          event = jsonDecode(message);
        } catch (e) {
          print(
              "[WebSocketService] Error decoding JSON: $e, Raw message: $message");
          if (!_isDisposed)
            _errorController.add("WebSocket JSON parsing error: $e");
          return;
        }

        final payload = event['payload'];
        switch (event['type']) {
          case 'initial_state':
            if (payload is Map<String, dynamic>) {
              final channels =
                  payload['channels'] as Map<String, dynamic>? ?? {};
              if (!_isDisposed)
                _initialStateController.add({'channels': channels});
              print(
                  "[WebSocketService] Forwarded initial state payload with ${channels.keys.length} channels.");
            }
            break;
          case 'message':
            String channelName = payload['channel_name']?.toLowerCase() ?? '';
            final bool isPrivateMessage = !channelName.startsWith('#');

            String conversationTarget;
            if (isPrivateMessage) {
              conversationTarget =
                  channelName.startsWith('@') ? channelName : '@$channelName';
            } else {
              conversationTarget = channelName;
            }

            if (!_isDisposed)
              _messageController.add({
                'channel_name': conversationTarget,
                'sender': payload['sender'],
                'text': payload['text'],
                'time': payload['time'] ?? DateTime.now().toIso8601String(),
              });
            break;
          case 'members_update':
            final String channelName = payload['channel_name'];
            final List<dynamic> membersData = payload['members'] ?? [];
            final List<ChannelMember> members =
                membersData.map((m) => ChannelMember.fromJson(m)).toList();
            if (!_isDisposed)
              _membersUpdateController
                  .add({'channel_name': channelName, 'members': members});
            break;
          case 'unauthorized':
            _handleUnauthorized();
            break;
          default:
            if (!_isDisposed && event['type'] != null && payload != null) {
              _eventController.add({'type': event['type'], 'payload': payload});
              print(
                  "[WebSocketService] Event forwarded to eventStream: type=${event['type']} payload=${jsonEncode(payload)}");
            }
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
    if (!_isDisposed) _statusController.add(WebSocketStatus.unauthorized);
    disconnect();

    Future.delayed(const Duration(milliseconds: 500), () {
      AuthManager.forceLogout(showExpiredMessage: true);
    });
  }

  void _handleWebSocketError(dynamic error) {
    if (!_isDisposed) {
      _errorController.add("WebSocket Error: $error");
      _statusController.add(WebSocketStatus.error);
    }
    _scheduleReconnect();
  }

  void _handleWebSocketDone() {
    print("[WebSocketService] Connection closed.");
    if (_isDisposed) return;
    if (_currentWsStatus != WebSocketStatus.unauthorized) {
      _statusController.add(WebSocketStatus.disconnected);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_token != null &&
          _currentWsStatus != WebSocketStatus.connecting &&
          _currentWsStatus != WebSocketStatus.connected &&
          _currentWsStatus != WebSocketStatus.unauthorized &&
          !_isDisposed) {
        print("[WebSocketService] Attempting to reconnect...");
        connect(_token!);
      }
    });
  }

  bool _isUnauthorized(String error) {
    return error.contains('401 Unauthorized') ||
        error.contains('invalid token') ||
        error.toString().contains('not upgraded to websocket: 401') ||
        error.contains('401') ||
        error.contains('unauthorized');
  }

  void sendMessage(String channelName, String text) {
    if (_isDisposed) return;
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      if (!_isDisposed)
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

  void send(Map<String, dynamic> message) {
    if (_isDisposed) return;
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      if (!_isDisposed)
        _errorController.add("Cannot send event: WebSocket not connected.");
      print("[WebSocketService] Cannot send event: WS not connected.");
      return;
    }
    final messageToSend = jsonEncode(message);
    _ws?.sink.add(messageToSend);
    print("[WebSocketService] Sent event: $messageToSend");
  }

  /// A more robust disconnect method that properly cleans up state to prevent
  /// reconnect loops with invalid tokens.
  void disconnect() {
    if (_isDisposed) return;

    print("[WebSocketService] Disconnecting and clearing state...");

    // 1. Cancel any pending reconnect timers to stop the loop.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // 2. Close the WebSocket sink and clear the channel object.
    _ws?.sink.close();
    _ws = null;

    // 3. Clear the stale token to prevent it from being reused.
    _token = null;

    // 4. Update the status, if the service hasn't been disposed.
    if (!_isDisposed) {
      _statusController.add(WebSocketStatus.disconnected);
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    disconnect(); // Call the new, more robust disconnect method.
    _statusController.close();
    _messageController.close();
    _membersUpdateController.close();
    _initialStateController.close();
    _errorController.close();
    _eventController.close();
  }
}

