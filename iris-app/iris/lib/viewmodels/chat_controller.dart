import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/main.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../services/notification_service.dart';
import '../services/encryption_service.dart';
import 'chat_state.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/encryption_session.dart';
import '../config.dart';

class ChatController {
  final String username;
  final String token;
  final ChatState chatState;
  final ApiService apiService;
  final WebSocketService _webSocketService;
  final NotificationService _notificationService;
  final EncryptionService _encryptionService;

  WebSocketStatus _currentWsStatus = WebSocketStatus.disconnected;

  final StreamController<WebSocketStatus> _wsStatusController = StreamController.broadcast();
  Stream<WebSocketStatus> get wsStatusStream => _wsStatusController.stream;

  final StreamController<String?> _errorController = StreamController.broadcast();
  Stream<String?> get errorStream => _errorController.stream;

  ChatController({
    required this.username,
    required this.token,
    required this.chatState,
  })  : apiService = ApiService(token),
        _webSocketService = GetIt.instance<WebSocketService>(),
        _notificationService = GetIt.instance<NotificationService>(),
        _encryptionService = GetIt.instance<EncryptionService>();

  Future<void> initialize() async {
    await chatState.loadPersistedMessages();
    chatState.setAvatarPlaceholder(username);
    await loadAvatarForUser(username);

    // --- NEW: Load any pending DM messages from when the app was closed ---
    final prefs = await SharedPreferences.getInstance();
    final pendingMessages = prefs.getStringList('pending_dm_messages') ?? [];
    for (final messageJson in pendingMessages) {
      try {
        final messageData = json.decode(messageJson) as Map<String, dynamic>;
        final sender = messageData['sender'];
        if (sender != null) {
          final channelName = '@$sender';
          final content = messageData['message'] ?? messageData['body'] ?? messageData['content'] ?? '';
          final newMessage = Message.fromJson({
            'from': sender,
            'content': content,
            'time': messageData['time'] ?? DateTime.now().toIso8601String(),
            'id': messageData['id'] ?? 'pending-${DateTime.now().millisecondsSinceEpoch}',
          });
          chatState.addMessage(channelName, newMessage);
        }
      } catch (e) {
        print('Error loading pending message: $e');
      }
    }
    await prefs.remove('pending_dm_messages');
    // ------------------------------------------------------------

    _listenToWebSocketStatus();
    _listenToInitialState();
    _listenToWebSocketMessages();
    _listenToMembersUpdate();
    _listenToWebSocketErrors();

    _initNotifications();
    _handlePendingNotification();
  }

  void connectWebSocket() {
    if (_currentWsStatus == WebSocketStatus.disconnected ||
        _currentWsStatus == WebSocketStatus.error) {
      _webSocketService.connect(token);
    }
  }

  void disconnectWebSocket() {
    if (_currentWsStatus == WebSocketStatus.connected) {
      _webSocketService.disconnect();
    }
    _currentWsStatus = WebSocketStatus.disconnected;
    _wsStatusController.add(_currentWsStatus);
  }

  void _listenToWebSocketStatus() {
    _webSocketService.statusStream.listen((status) {
      _currentWsStatus = status;
      _wsStatusController.add(status);
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
    });
  }

  void _listenToInitialState() {
    _webSocketService.initialStateStream.listen((payload) async {
      final channelsPayload = payload['channels'] as Map<String, dynamic>?;
      final List<Channel> websocketChannels = [];

      if (channelsPayload != null) {
        channelsPayload.forEach((channelName, channelData) {
          final channel = Channel.fromJson(channelData as Map<String, dynamic>);
          websocketChannels.add(channel);
          for (var member in channel.members) {
            loadAvatarForUser(member.nick);
          }
        });
      }
      chatState.mergeChannels(websocketChannels);
      _errorController.add(null);
    }).onError((e) {
      _errorController.add("Error receiving initial state: $e");
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) async {
      final String sender = message['sender'] ?? 'Unknown';
      String text = message['text'] ?? '';

      if (text.startsWith('[ENCRYPTION-REQUEST] ')) {
        await _handleEncryptionRequest(sender, text);
        return;
      }
      if (text.startsWith('[ENCRYPTION-ACCEPT] ')) {
        await _handleEncryptionAccept(sender, text);
        return;
      }
      if (text.startsWith('[ENCRYPTION-END]')) {
        _handleEncryptionEnd(sender);
        return;
      }
      if (text.startsWith('[ENC]')) {
        await _handleEncryptedMessage(sender, text);
        return;
      }

      final encStatus = _encryptionService.getSessionStatus('@$sender');
      if (encStatus == EncryptionStatus.active) {
         chatState.addSystemMessage(
            '@$sender', '⚠️ WARNING: Received an unencrypted message during a secure session. The session has been terminated for your safety. Please re-initiate encryption.');
         _encryptionService.endEncryption('@$sender');
         chatState.setEncryptionStatus('@$sender', EncryptionStatus.error);
         return;
      }

      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final bool isPrivateMessage = !channelName.startsWith('#');

      String conversationTarget;
      if (isPrivateMessage) {
        // --- FIX: Always use @<recipient/target> for private messages ---
        // For DMs, the channel name is @<recipient>, regardless of sender
        // If the channelName is already in @ format, use it directly, otherwise, prefix with @
        conversationTarget = channelName.startsWith('@') ? channelName : '@$channelName';
        if (chatState.channels.indexWhere((c) => c.name.toLowerCase() == conversationTarget.toLowerCase()) == -1) {
            chatState.addOrUpdateChannel(Channel(name: conversationTarget, members: []));
        }
      } else {
        conversationTarget = channelName;
      }

      final newMessage = Message.fromJson({
        'from': sender,
        'content': text,
        'time': message['time'] ?? DateTime.now().toIso8601String(),
        'id': message['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      });

      chatState.addMessage(conversationTarget, newMessage);
      loadAvatarForUser(sender);
    });

    // ----------- CHANNEL TOPIC SUPPORT -----------
    _webSocketService.eventStream.listen((event) {
      final String eventType = event['type'] ?? '';
      final payload = event['payload'] ?? {};

      if (eventType == 'topic_change') {
        final channelName = payload['channel'] as String?;
        final topic = payload['topic'] as String?;
        if (channelName != null && topic != null) {
          final updatedChannels = chatState.channels.map((c) {
            if (c.name.toLowerCase() == channelName.toLowerCase()) {
              return Channel(
                name: c.name,
                topic: topic,
                members: c.members,
              );
            }
            return c;
          }).toList();
          chatState.setChannels(updatedChannels);
        }
      }
    });
    // ----------- END CHANNEL TOPIC SUPPORT -----------
  }

  void _listenToMembersUpdate() {
    _webSocketService.membersUpdateStream.listen((update) {
      final String channelName = update['channel_name'];
      final List<dynamic> membersRaw = update['members'];
      final List<ChannelMember> newMembers = membersRaw
          .map((m) => m is ChannelMember ? m : ChannelMember.fromJson(m))
          .toList();

      chatState.updateChannelMembers(channelName, newMembers);
      for (var member in newMembers) {
        loadAvatarForUser(member.nick);
      }
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      _errorController.add(error);
    });
  }

  // START OF CHANGE
  /// Sends a raw structured message to the WebSocket.
  /// This is used for commands that are not standard chat messages, like 'topic_change'.
  void sendRawWebSocketMessage(Map<String, dynamic> message) {
    // Note: This assumes your WebSocketService has a generic `send` method
    // for sending any JSON object to the server, as the existing `sendMessage`
    // is specific to sending chat messages (PRIVMSG).
    _webSocketService.send(message);
  }
  // END OF CHANGE

  Future<void> handleSendMessage(String text) async {
    if (text.trim().isEmpty) return;

    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }

    final currentConversation = chatState.selectedConversationTarget;
    final isDm = currentConversation.startsWith('@');
    String target = isDm ? currentConversation.substring(1) : currentConversation;

    // Always add own message to chatState for DMs
    final sentMessage = Message(
      from: username,
      content: text,
      time: DateTime.now(),
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      isEncrypted: isDm && _encryptionService.getSessionStatus(currentConversation) == EncryptionStatus.active,
    );
    chatState.addMessage(currentConversation, sentMessage);

    if (isDm && _encryptionService.getSessionStatus(currentConversation) == EncryptionStatus.active) {
        final encryptedText = await _encryptionService.encryptMessage(currentConversation, text);
        if (encryptedText != null) {
            _webSocketService.sendMessage(target, encryptedText);
        } else {
            chatState.addSystemMessage(currentConversation, 'Could not encrypt message. Session may be invalid.');
        }
        return;
    }

    _webSocketService.sendMessage(target, text);
  }

  Future<void> initiateOrEndEncryption() async {
    final target = chatState.selectedConversationTarget;
    if (!target.startsWith('@')) return;

    final status = _encryptionService.getSessionStatus(target);

    if (status == EncryptionStatus.active || status == EncryptionStatus.error) {
      final endMessage = _encryptionService.endEncryption(target);
      _webSocketService.sendMessage(target.substring(1), endMessage);
      chatState.setEncryptionStatus(target, EncryptionStatus.none);
      chatState.addSystemMessage(target, 'Encryption has been terminated.');

    } else if (status == EncryptionStatus.none || status == EncryptionStatus.pending) {
       final requestMessage = await _encryptionService.initiateEncryption(target);
       if(requestMessage != null) {
          _webSocketService.sendMessage(target.substring(1), requestMessage);
          chatState.setEncryptionStatus(target, EncryptionStatus.pending);
          chatState.addSystemMessage(target, 'Attempting to start an encrypted session...');
       }
    }
  }

  Future<void> _handleEncryptionRequest(String from, String text) async {
      final payload = text.substring('[ENCRYPTION-REQUEST] '.length);
      final response = await _encryptionService.handleEncryptionRequest('@$from', payload);
      if (response != null) {
          _webSocketService.sendMessage(from, response);
          chatState.setEncryptionStatus('@$from', EncryptionStatus.active);
          chatState.addSystemMessage('@$from', 'Accepted encryption request. Session is now active.');
      } else {
          chatState.setEncryptionStatus('@$from', EncryptionStatus.error);
          chatState.addSystemMessage('@$from', 'Failed to process encryption request.');
      }
  }

  Future<void> _handleEncryptionAccept(String from, String text) async {
      final payload = text.substring('[ENCRYPTION-ACCEPT] '.length);
      await _encryptionService.handleEncryptionAcceptance('@$from', payload);
      chatState.setEncryptionStatus('@$from', EncryptionStatus.active);
      chatState.addSystemMessage('@$from', 'Encryption request accepted. Session is now active.');
  }

  Future<void> _handleEncryptedMessage(String from, String text) async {
      final payload = text.substring('[ENC]'.length);
      final decrypted = await _encryptionService.decryptMessage('@$from', payload);

      if(decrypted != null) {
          final msg = Message(
            from: from,
            content: decrypted,
            time: DateTime.now(),
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            isEncrypted: true
          );
          chatState.addMessage('@$from', msg);
      } else {
          chatState.addSystemMessage('@$from', '⚠️ Could not decrypt a message. The secure session may have been compromised and has been ended.');
          chatState.setEncryptionStatus('@$from', EncryptionStatus.error);
      }
  }

  void _handleEncryptionEnd(String from) {
     _encryptionService.endEncryption('@$from');
     chatState.setEncryptionStatus('@$from', EncryptionStatus.none);
     chatState.addSystemMessage('@$from', 'The other user has ended the encrypted session.');
  }

  Future<String?> getSafetyNumberForTarget() {
      final target = chatState.selectedConversationTarget;
      return _encryptionService.getSafetyNumber(target);
  }

  Future<void> joinChannel(String channelName) async {
    try {
      await apiService.joinChannel(channelName);
      chatState.selectConversation(channelName);
      chatState.moveChannelToJoined(channelName, username);
      await loadChannelHistory(channelName, limit: 100);
    } catch (e) {
      chatState.addSystemMessage(chatState.selectedConversationTarget, 'Failed to join channel: $channelName. Error: $e');
    }
  }

  Future<void> partChannel(String channelName) async {
    if (!channelName.startsWith('#')) {
      chatState.addSystemMessage(chatState.selectedConversationTarget, 'You can only part public channels.');
      return;
    }
    try {
      await apiService.partChannel(channelName);
      chatState.moveChannelToUnjoined(channelName);
    } catch (e) {
      chatState.addSystemMessage(chatState.selectedConversationTarget, 'Failed to leave channel: ${e.toString()}');
    }
  }

  Future<void> loadChannelHistory(String channelName, {int limit = 100}) async {
    if (channelName.isEmpty) return;
    try {
      final response = await apiService.fetchChannelMessages(channelName, limit: limit);
      final messages = response.map((item) => Message.fromJson({
        ...item,
        'isHistorical': true,
        'id': item['id'] ?? 'hist-${item['time']}-${item['from']}',
      })).toList();

      messages.sort((a, b) => a.time.compareTo(b.time));

      if (messages.isNotEmpty) {
        chatState.addMessageBatch(channelName, messages);
        final senders = messages.map((m) => m.from).toSet();
        for (final sender in senders) {
          await loadAvatarForUser(sender);
        }
      }
    } catch (e) {
      print('Error loading channel history for $channelName: $e');
      chatState.addSystemMessage(channelName, 'Failed to load history for $channelName.');
    }
  }

  Future<String?> uploadAttachmentAndGetUrl(String filePath) async {
    try {
      final file = File(filePath);
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://$apiHost:$apiPort/api/upload-attachment'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseBody);

      if (response.statusCode == 200 && jsonResponse['success'] == true) {
        final fileUrl = jsonResponse['url'];
        final fullFileUrl = 'http://$apiHost:$apiPort$fileUrl';
        return fullFileUrl;
      } else {
        chatState.addSystemMessage('IRIS Bot','Failed to upload attachment: ${jsonResponse['message'] ?? 'Unknown error'}');
        return null;
      }
    } catch (e) {
      chatState.addSystemMessage('IRIS Bot', 'Attachment upload failed: $e');
      return null;
    }
  }

  Future<void> loadAvatarForUser(String nick) async {
    if (nick.isEmpty || chatState.hasAvatar(nick)) return;
    chatState.setAvatarPlaceholder(nick);
    final exts = ['.png', '.jpg', '.jpeg', '.gif'];
    for (final ext in exts) {
      final url = 'http://$apiHost:$apiPort/avatars/$nick$ext';
      try {
        final response = await http.head(Uri.parse(url));
        if (response.statusCode == 200) {
          chatState.setAvatar(nick, url);
          return;
        }
      } catch (e) { /* Ignore */ }
    }
  }

  Future<void> _handleCommand(String commandText) async {
    final parts = commandText.substring(1).split(' ');
    final command = parts[0].toLowerCase();
    final args = parts.skip(1).join(' ').trim();

    switch (command) {
      case 'join':
        if (args.isNotEmpty && args.startsWith('#')) {
          joinChannel(args);
        } else {
          chatState.addSystemMessage(chatState.selectedConversationTarget, 'Usage: /join <#channel_name>');
        }
        break;
      case 'part':
        String channelToPart = args.isNotEmpty ? args : chatState.selectedConversationTarget;
        if (channelToPart.isNotEmpty && channelToPart.startsWith('#')) {
          partChannel(channelToPart);
        } else {
          chatState.addSystemMessage(chatState.selectedConversationTarget, 'Usage: /part [#channel_name]');
        }
        break;
      default:
        chatState.addSystemMessage(chatState.selectedConversationTarget, 'Unknown command: /$command.');
    }
  }

  void _initNotifications() async {
    final fcmToken = await _notificationService.getFCMToken();
    if (fcmToken != null) {
      await apiService.registerFCMToken(fcmToken);
    }
  }

  void handleNotificationTap(String channelName) {
    if (channelName.startsWith('@') && chatState.channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase()) == -1) {
      chatState.addOrUpdateChannel(Channel(name: channelName, members: []));
    }
    chatState.selectConversation(channelName);
  }

  void _handlePendingNotification() async {
    if (PendingNotification.channelToNavigateTo != null) {
      final channelName = PendingNotification.channelToNavigateTo!;
      final messageData = PendingNotification.messageData;

      // Ensure the DM channel exists and add the message if present
      if (chatState.channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase()) == -1) {
        chatState.addOrUpdateChannel(Channel(name: channelName, members: []));
      }

      if (messageData != null) {
        final content = messageData['message'] ?? messageData['body'] ?? messageData['content'] ?? '';
        final newMessage = Message.fromJson({
          'from': messageData['sender'] ?? 'Unknown',
          'content': content,
          'time': messageData['time'] ?? DateTime.now().toIso8601String(),
          'id': messageData['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        });
        chatState.addMessage(channelName, newMessage);
      }

      // Navigate to the channel
      handleNotificationTap(channelName);

      // Clear the pending notification
      PendingNotification.channelToNavigateTo = null;
      PendingNotification.messageData = null;
    }
  }

  Future<void> _handleLogout() async {
    _webSocketService.dispose();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    AuthWrapper.forceLogout();
  }

  void dispose() {
    _wsStatusController.close();
    _errorController.close();
  }
}