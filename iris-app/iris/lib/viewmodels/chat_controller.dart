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
import '../services/notification_service_platform.dart';
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
  final bool Function() isAppInBackground;
  final ApiService apiService;
  final WebSocketService _webSocketService;
  final NotificationService _notificationService;
  final EncryptionService _encryptionService;

  WebSocketStatus _currentWsStatus = WebSocketStatus.disconnected;

  StreamSubscription? _wsStatusSub;
  StreamSubscription? _initialStateSub;
  StreamSubscription? _messageSub;
  StreamSubscription? _membersUpdateSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _eventSub;

  final StreamController<WebSocketStatus> _wsStatusController =
      StreamController.broadcast();
  Stream<WebSocketStatus> get wsStatusStream => _wsStatusController.stream;

  final StreamController<String?> _errorController = StreamController.broadcast();
  Stream<String?> get errorStream => _errorController.stream;

  ChatController({
    required this.username,
    required this.token,
    required this.chatState,
    required this.isAppInBackground,
  })  : apiService = ApiService(token),
        _webSocketService = GetIt.instance<WebSocketService>(),
        _notificationService = GetIt.instance<NotificationService>(),
        _encryptionService = GetIt.instance<EncryptionService>();

  Future<void> initialize() async {
    await chatState.loadPersistedMessages();
    chatState.setAvatarPlaceholder(username);
    await loadAvatarForUser(username);

    final prefs = await SharedPreferences.getInstance();
    final pendingMessages = prefs.getStringList('pending_dm_messages') ?? [];
    for (final messageJson in pendingMessages) {
      try {
        final messageData = json.decode(messageJson) as Map<String, dynamic>;
        final sender = messageData['sender'];
        if (sender != null) {
          final channelName = '@$sender';
          final content = messageData['message'] ??
              messageData['body'] ??
              messageData['content'] ??
              '';
          final newMessage = Message.fromJson({
            'from': sender,
            'content': content,
            'time': messageData['time'] ?? DateTime.now().toIso8601String(),
            'id': messageData['id'] ??
                'pending-${DateTime.now().millisecondsSinceEpoch}',
          });
          chatState.addMessage(channelName, newMessage);
        }
      } catch (e) {
        print('Error loading pending message: $e');
      }
    }
    await prefs.remove('pending_dm_messages');

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
    _wsStatusSub = _webSocketService.statusStream.listen((status) {
      _currentWsStatus = status;
      _wsStatusController.add(status);
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
    });
  }

  Future<void> restoreLastKnownChannelState() async {
    final lastKnownChannels = await chatState.loadPersistedJoinedChannels();

    if (lastKnownChannels.isNotEmpty) {
      print(
          '[ChatController] No channels joined on server. Restoring from local state: $lastKnownChannels');
      for (final channelName in lastKnownChannels) {
        if (channelName.startsWith('#')) {
          try {
            await apiService.joinChannel(channelName);
          } catch (e) {
            print(
                '[ChatController] Failed to auto-re-join channel $channelName: $e');
          }
        }
      }
    } else {
      print(
          '[ChatController] No channels joined and no local state found. Joining #welcome.');
      try {
        await joinChannel('#welcome');
      } catch (e) {
        print('[ChatController] Failed to join #welcome: $e');
        chatState.addSystemMessage(chatState.selectedConversationTarget,
            'Failed to join #welcome channel.');
      }
    }
  }

  void _listenToInitialState() {
    _initialStateSub =
        _webSocketService.initialStateStream.listen((payload) async {
      final channelsPayload = payload['channels'] as Map<String, dynamic>?;
      final List<Channel> websocketChannels = [];

      if (channelsPayload != null) {
        channelsPayload.forEach((channelName, channelData) {
          final data = channelData as Map<String, dynamic>;
          if (!data.containsKey('name') ||
              data['name'] == null ||
              (data['name'] as String).isEmpty) {
            data['name'] = channelName;
          }
          final channel = Channel.fromJson(data);
          websocketChannels.add(channel);
          for (var member in channel.members) {
            loadAvatarForUser(member.nick);
          }
        });
      }
      chatState.mergeChannels(websocketChannels);

      final bool isJoinedToAnyPublicChannel = chatState.channels
          .any((c) => c.name.startsWith('#') && c.members.isNotEmpty);

      if (!isJoinedToAnyPublicChannel) {
        await restoreLastKnownChannelState();
      }

      _errorController.add(null);
    })..onError((e) {
      _errorController.add("Error receiving initial state: $e");
    });
  }

  void _listenToWebSocketMessages() {
    _messageSub = _webSocketService.messageStream.listen((message) async {
      if (isAppInBackground() && message['type'] == 'message') {
        final payload = message['payload'] as Map<String, dynamic>? ?? {};
        final String sender = payload['sender'] ?? 'Unknown';

        if (sender.toLowerCase() != username.toLowerCase()) {
          final String text = payload['text'] ?? '';
          final String channelName = payload['channel_name'] ?? '';
          _notificationService.showSimpleNotification(
              title: sender,
              body: text,
              payload: {
                'sender': sender,
                'channel_name': channelName,
                'type': channelName.startsWith('@')
                    ? 'private_message'
                    : 'channel_message'
              });
        }
      }

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
        chatState.addSystemMessage('@$sender',
            '⚠️ WARNING: Received an unencrypted message during a secure session. The session has been terminated for your safety. Please re-initiate encryption.');
        _encryptionService.endEncryption('@$sender');
        chatState.setEncryptionStatus('@$sender', EncryptionStatus.error);
        return;
      }

      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final bool isPrivateMessage = !channelName.startsWith('#');

      String conversationTarget;
      if (isPrivateMessage) {
        conversationTarget =
            channelName.startsWith('@') ? channelName : '@$channelName';
        if (chatState.channels.indexWhere(
                (c) => c.name.toLowerCase() == conversationTarget.toLowerCase()) ==
            -1) {
          chatState.addOrUpdateChannel(
              Channel(name: conversationTarget, members: []));
        }
      } else {
        conversationTarget = channelName;
      }

      final newMessage = Message.fromJson({
        'from': sender,
        'content': text,
        'time': message['time'] ?? DateTime.now().toIso8601String(),
        'id':
            message['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      });

      chatState.addMessage(conversationTarget, newMessage);
      loadAvatarForUser(sender);
    });

    _eventSub = _webSocketService.eventStream.listen((event) {
      final String eventType = event['type'] ?? '';
      final payload = event['payload'] ?? {};
      final String? channelName =
          payload['channel_name'] as String? ?? payload['channel'] as String?;
      final String? sender = payload['sender'] as String?;
      final String? text = payload['text'] as String?;
      final String? topic = payload['topic'] as String?;
      final String? time = payload['time'] as String?;

      if (channelName == null) return;

      switch (eventType) {
        case 'topic_change':
          if (topic != null) {
            chatState.updateChannelTopic(channelName, topic);
          }
          break;
        case 'notice':
          if (sender != null && text != null) {
            // Check if it's a pronoun notice from the gateway and suppress/handle it.
            if (sender.toLowerCase() == gatewayNick.toLowerCase() &&
                text.toLowerCase().contains('pronouns')) {
              final RegExp pronounRegex = RegExp(r"(.+)'s pronouns are (.+)");
              final match = pronounRegex.firstMatch(text);
              if (match != null) {
                final parsedUser = match.group(1);
                final parsedPronouns = match.group(2);
                if (parsedUser != null && parsedPronouns != null) {
                  print(
                      "[ChatController] Parsed pronouns for $parsedUser: $parsedPronouns");
                  chatState.setUserPronouns(parsedUser, parsedPronouns);
                  return; // Suppress the notice from appearing in chat
                }
              }
            }

            // If it's not a pronoun notice, show it normally.
            final noticeMessage = Message.fromJson({
              'from': sender,
              'content': text,
              'time': time ?? DateTime.now().toIso8601String(),
              'isNotice': true,
            });
            chatState.addMessage(channelName, noticeMessage);
          }
          break;
      }
    });
  }

  void _listenToMembersUpdate() {
    _membersUpdateSub = _webSocketService.membersUpdateStream.listen((update) {
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
    _errorSub = _webSocketService.errorStream.listen((error) {
      _errorController.add(error);
    });
  }

  void sendRawWebSocketMessage(Map<String, dynamic> message) {
    _webSocketService.send(message);
  }

  Future<void> handleSendMessage(String text) async {
    if (text.trim().isEmpty) return;

    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }

    final currentConversation = chatState.selectedConversationTarget;
    final isDm = currentConversation.startsWith('@');
    String target =
        isDm ? currentConversation.substring(1) : currentConversation;

    final sentMessage = Message(
      from: username,
      content: text,
      time: DateTime.now(),
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      isEncrypted: isDm &&
          _encryptionService.getSessionStatus(currentConversation) ==
              EncryptionStatus.active,
    );
    chatState.addMessage(currentConversation, sentMessage);

    if (isDm &&
        _encryptionService.getSessionStatus(currentConversation) ==
            EncryptionStatus.active) {
      final encryptedText =
          await _encryptionService.encryptMessage(currentConversation, text);
      if (encryptedText != null) {
        _webSocketService.sendMessage(target, encryptedText);
      } else {
        chatState.addSystemMessage(currentConversation,
            'Could not encrypt message. Session may be invalid.');
      }
      return;
    }

    _webSocketService.sendMessage(target, text);
  }

  Future<void> setMyPronouns(String pronouns) async {
    final command = '!$gatewayNick set pronouns $pronouns';
    // Send the command as a private message to the gateway bot.
    // The gateway bot listens for its own name in PMs to process commands.
    _webSocketService.sendMessage(gatewayNick, command);
    chatState.addSystemMessage(
      chatState.selectedConversationTarget,
      'Pronouns updated to "$pronouns".',
    );
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
    } else if (status == EncryptionStatus.none ||
        status == EncryptionStatus.pending) {
      final requestMessage =
          await _encryptionService.initiateEncryption(target);
      if (requestMessage != null) {
        _webSocketService.sendMessage(target.substring(1), requestMessage);
        chatState.setEncryptionStatus(target, EncryptionStatus.pending);
        chatState.addSystemMessage(
            target, 'Attempting to start an encrypted session...');
      }
    }
  }

  Future<void> _handleEncryptionRequest(String from, String text) async {
    final payload = text.substring('[ENCRYPTION-REQUEST] '.length);
    final response =
        await _encryptionService.handleEncryptionRequest('@$from', payload);
    if (response != null) {
      _webSocketService.sendMessage(from, response);
      chatState.setEncryptionStatus('@$from', EncryptionStatus.active);
      chatState.addSystemMessage(
          '@$from', 'Accepted encryption request. Session is now active.');
    } else {
      chatState.setEncryptionStatus('@$from', EncryptionStatus.error);
      chatState.addSystemMessage(
          '@$from', 'Failed to process encryption request.');
    }
  }

  Future<void> _handleEncryptionAccept(String from, String text) async {
    final payload = text.substring('[ENCRYPTION-ACCEPT] '.length);
    await _encryptionService.handleEncryptionAcceptance('@$from', payload);
    chatState.setEncryptionStatus('@$from', EncryptionStatus.active);
    chatState.addSystemMessage(
        '@$from', 'Encryption request accepted. Session is now active.');
  }

  Future<void> _handleEncryptedMessage(String from, String text) async {
    final payload = text.substring('[ENC]'.length);
    final decrypted =
        await _encryptionService.decryptMessage('@$from', payload);

    if (decrypted != null) {
      final msg = Message(
        from: from,
        content: decrypted,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        isEncrypted: true,
      );
      chatState.addMessage('@$from', msg);
    } else {
      chatState.addSystemMessage('@$from',
          '⚠️ Could not decrypt a message. The secure session may have been compromised and has been ended.');
      chatState.setEncryptionStatus('@$from', EncryptionStatus.error);
    }
  }

  void _handleEncryptionEnd(String from) {
    _encryptionService.endEncryption('@$from');
    chatState.setEncryptionStatus('@$from', EncryptionStatus.none);
    chatState.addSystemMessage(
        '@$from', 'The other user has ended the encrypted session.');
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
      await loadChannelHistory(channelName, limit: 2500);
    } catch (e) {
      chatState.addSystemMessage(chatState.selectedConversationTarget,
          'Failed to join channel: $channelName. Error: $e');
    }
  }

  Future<void> partChannel(String channelName) async {
    if (!channelName.startsWith('#')) {
      chatState.addSystemMessage(chatState.selectedConversationTarget,
          'You can only part public channels.');
      return;
    }
    try {
      await apiService.partChannel(channelName);
      chatState.moveChannelToUnjoined(channelName);
    } catch (e) {
      chatState.addSystemMessage(chatState.selectedConversationTarget,
          'Failed to leave channel: ${e.toString()}');
    }
  }

  Future<void> loadChannelHistory(String channelName,
      {int limit = 2500}) async {
    if (channelName.isEmpty) return;
    try {
      final response =
          await apiService.fetchChannelMessages(channelName, limit: limit);
      final messages = response
          .map((item) => Message.fromJson({
                ...item,
                'isHistorical': true,
                'id': item['id'] ?? 'hist-${item['time']}-${item['from']}',
              }))
          .toList();

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
      chatState.addSystemMessage(
          channelName, 'Failed to load history for $channelName.');
    }
  }

  Future<String?> uploadAttachmentAndGetUrl(String filePath) async {
    try {
      final file = File(filePath);
      final fullUrl = await apiService.uploadAttachmentAndGetUrl(file);
      if (fullUrl != null) {
        return fullUrl;
      }
      return null;
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
      final url = '$baseSecureUrl/avatars/$nick$ext';
      try {
        final response = await http.head(Uri.parse(url));
        if (response.statusCode == 200) {
          chatState.setAvatar(nick, url);
          return;
        }
      } catch (e) {
        /* Ignore */
      }
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
          chatState.addSystemMessage(chatState.selectedConversationTarget,
              'Usage: /join <#channel_name>');
        }
        break;
      case 'part':
        String channelToPart =
            args.isNotEmpty ? args : chatState.selectedConversationTarget;
        if (channelToPart.isNotEmpty && channelToPart.startsWith('#')) {
          partChannel(channelToPart);
        } else {
          chatState.addSystemMessage(chatState.selectedConversationTarget,
              'Usage: /part [#channel_name]');
        }
        break;
      default:
        chatState.addSystemMessage(
            chatState.selectedConversationTarget, 'Unknown command: /$command.');
    }
  }

  void _initNotifications() async {
    final fcmToken = await _notificationService.getFCMToken();
    if (fcmToken != null) {
      await apiService.registerFCMToken(fcmToken);
    }
  }

  void handleNotificationTap(String channelName) {
    if (channelName.startsWith('@') &&
        chatState.channels.indexWhere(
                (c) => c.name.toLowerCase() == channelName.toLowerCase()) ==
            -1) {
      chatState.addOrUpdateChannel(Channel(name: channelName, members: []));
    }
    chatState.selectConversation(channelName);
  }

  void _handlePendingNotification() async {
    if (PendingNotification.channelToNavigateTo != null) {
      final channelName = PendingNotification.channelToNavigateTo!;
      final messageData = PendingNotification.messageData;

      if (chatState.channels.indexWhere(
              (c) => c.name.toLowerCase() == channelName.toLowerCase()) ==
          -1) {
        chatState.addOrUpdateChannel(Channel(name: channelName, members: []));
      }

      if (messageData != null) {
        final content = messageData['message'] ??
            messageData['body'] ??
            messageData['content'] ??
            '';
        final newMessage = Message.fromJson({
          'from': messageData['sender'] ?? 'Unknown',
          'content': content,
          'time': messageData['time'] ?? DateTime.now().toIso8601String(),
          'id': messageData['id'] ??
              DateTime.now().millisecondsSinceEpoch.toString(),
        });
        chatState.addMessage(channelName, newMessage);
      }

      handleNotificationTap(channelName);

      PendingNotification.channelToNavigateTo = null;
      PendingNotification.messageData = null;
    }
  }

  Future<void> _handleLogout() async {
    _webSocketService.dispose();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    AuthManager.forceLogout();
  }

  void dispose() {
    _wsStatusSub?.cancel();
    _initialStateSub?.cancel();
    _messageSub?.cancel();
    _membersUpdateSub?.cancel();
    _errorSub?.cancel();
    _eventSub?.cancel();
    _wsStatusController.close();
    _errorController.close();
  }
}