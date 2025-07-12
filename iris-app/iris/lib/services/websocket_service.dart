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
  int _reconnectAttempts = 0;
  final int _maxReconnectAttempts = 10;
  final Duration _reconnectDelay = const Duration(seconds: 5);

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
    if (_isDisposed) {
      print("[WebSocketService] Service disposed. Cannot connect.");
      return;
    }
    if (_currentWsStatus == WebSocketStatus.connected ||
        _currentWsStatus == WebSocketStatus.connecting ||
        _currentWsStatus == WebSocketStatus.unauthorized) {
      print(
          "[WebSocketService] Already connected/connecting/unauthorized. Skipping new connection attempt.");
      return;
    }

    _reconnectTimer?.cancel();
    _token = token;
    _statusController.add(WebSocketStatus.connecting);
    print("[WebSocketService] Attempting to connect to $websocketUrl...");

    final uri = Uri.parse("$websocketUrl/$token");
    try {
      _ws = WebSocketChannel.connect(uri);

      _ws!.ready.then((_) {
        _reconnectAttempts = 0;
        if (!_isDisposed) _statusController.add(WebSocketStatus.connected);
        print("[WebSocketService] Connected successfully to: $uri");
      }).catchError((e) {
        print("[WebSocketService] Initial connection error (WebSocketChannel.connect.then.catchError): $e");
        if (_isUnauthorized(e.toString())) {
          _handleUnauthorized();
        } else {
          _handleWebSocketError(e);
        }
      });

      _ws!.stream.listen((message) {
        if (_isDisposed) return;

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
              _initialStateController.add(payload);
              print(
                  "[WebSocketService] Forwarded initial state payload.");
            }
            break;
          case 'message':
            _messageController.add({
              'network_id': payload['network_id'],
              // =========================================================
              // === BEGIN FIX: Use the correct key from the server. ===
              // =========================================================
              'channel_name': payload['channel_name'], // Was payload['channel']
              // =========================================================
              // === END FIX =============================================
              // =========================================================
              'sender': payload['sender'],
              'text': payload['text'],
              'time': payload['time'], // Corrected from 'timestamp'
              'id': payload['id'],
              'isEncrypted': payload['is_encrypted'] ?? false,
              'isSystemInfo': payload['is_system_info'] ?? false,
              'isNotice': payload['is_notice'] ?? false,
            });
            break;
          case 'dm_message':
            _messageController.add({
              'network_id': payload['network_id'],
              'channel_name': payload['sender'],
              'sender': payload['sender'],
              'text': payload['message'],
              'time': payload['time'],
              'id': payload['id'],
              'isEncrypted': payload['is_encrypted'] ?? false,
              'isSystemInfo': payload['is_system_info'] ?? false,
              'isNotice': payload['is_notice'] ?? false,
            });
            break;
          case 'members_update':
            // PATCH: ensure 'channel' key is used to match newer logic, but pass it as-is (ChatController will fix as needed)
            _membersUpdateController
                .add({'network_id': payload['network_id'], 'channel': payload['channel'], 'members': payload['members']});
            break;
          case 'unauthorized':
            _handleUnauthorized();
            break;
          default:
            if (!_isDisposed && event['type'] != null && payload != null) {
              _eventController.add({'type': event['type'], 'payload': payload});
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
    AuthManager.forceLogout(showExpiredMessage: true);
  }

  void _handleWebSocketError(dynamic error) {
    if (_isDisposed) return;
    _errorController.add("WebSocket Error: $error");
    _statusController.add(WebSocketStatus.error);
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

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print("[WebSocketService] Max reconnect attempts reached. Not reattempting.");
      _errorController.add("Failed to reconnect after $_maxReconnectAttempts attempts. Please restart the app.");
      return;
    }

    // Do not reconnect if unauthorized or disposed.
    if (_currentWsStatus == WebSocketStatus.unauthorized) {
      print("[WebSocketService] Not reconnecting due to unauthorized status.");
      return;
    }

    _reconnectAttempts++;
    final int delaySeconds = _reconnectAttempts < 3 ? 2 : (_reconnectAttempts < 6 ? 5 : 10);
    print("[WebSocketService] Scheduling reconnect attempt $_reconnectAttempts in $delaySeconds seconds.");

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_token != null &&
          _currentWsStatus != WebSocketStatus.connecting &&
          _currentWsStatus != WebSocketStatus.connected &&
          _currentWsStatus != WebSocketStatus.unauthorized &&
          !_isDisposed) {
        print("[WebSocketService] Reconnecting (attempt $_reconnectAttempts)...");
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

  void sendMessage(int networkId, String channelName, String text) {
    if (_isDisposed) {
      print("[WebSocketService] Service disposed. Cannot send message.");
      return;
    }
    if (_ws == null || _currentWsStatus != WebSocketStatus.connected) {
      if (!_isDisposed)
        _errorController.add("Cannot send message: WebSocket not connected.");
      print("[WebSocketService] Cannot send message: WS not connected.");
      return;
    }
    final messageToSend = jsonEncode({
      'type': 'message',
      'payload': {
        'network_id': networkId,
        // FIX: Use 'channel_name' to match server expectation
        'channel_name': channelName,
        'text': text,
      },
    });
    _ws?.sink.add(messageToSend);
    print("[WebSocketService] Sent message: $messageToSend");
  }

  void send(Map<String, dynamic> message) {
    if (_isDisposed) {
      print("[WebSocketService] Service disposed. Cannot send event.");
      return;
    }
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

  void disconnect() {
    if (_isDisposed) return;

    print("[WebSocketService] Disconnecting and clearing state...");

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    _ws?.sink.close();
    _ws = null;

    _token = null;

    if (!_isDisposed) {
      _statusController.add(WebSocketStatus.disconnected);
    }
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    disconnect();
    _statusController.close();
    _messageController.close();
    _membersUpdateController.close();
    _initialStateController.close();
    _errorController.close();
    _eventController.close();
    print("[WebSocketService] Service fully disposed.");
  }
}