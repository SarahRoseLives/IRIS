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
import 'chat_state.dart';
import '../models/channel.dart'; // Use Channel and Message from here
import '../models/channel_member.dart';
import '../config.dart';

class ChatController {
  final String username;
  final String token;
  final ChatState chatState;
  final ApiService apiService;
  final WebSocketService _webSocketService;
  final NotificationService _notificationService;

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
        _notificationService = GetIt.instance<NotificationService>();

  // UPDATED: No longer auto-connects websocket here
  Future<void> initialize() async {
    await chatState.loadPersistedMessages();
    chatState.setAvatarPlaceholder(username);
    await loadAvatarForUser(username);

    _listenToWebSocketStatus();
    _listenToInitialState();
    _listenToWebSocketMessages();
    _listenToMembersUpdate();
    _listenToWebSocketErrors();

    // REMOVED: connectWebSocket();  // The ViewModel will now control this

    _initNotifications();
    _handlePendingNotification();
  }

  // PATCH: Update connectWebSocket to only connect if disconnected or error
  void connectWebSocket() {
    if (_currentWsStatus == WebSocketStatus.disconnected ||
        _currentWsStatus == WebSocketStatus.error) {
      _webSocketService.connect(token);
    }
  }

  // PATCH: Update disconnectWebSocket logic
  void disconnectWebSocket() {
    // Only disconnect if we're actually connected
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

  // UPDATED: Use mergeChannels instead of setChannels to avoid overwriting
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
      // Use mergeChannels to avoid clobbering cached DMs
      chatState.mergeChannels(websocketChannels);

      _errorController.add(null);

      // The ViewModel now handles fetching history after merging, so don't do it here.

    }).onError((e) {
      _errorController.add("Error receiving initial state: $e");
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';
      final bool isPrivateMessage = !channelName.startsWith('#');

      String conversationTarget;
      if (isPrivateMessage) {
        final String conversationPartner = (sender.toLowerCase() == username.toLowerCase()) ? channelName : sender;
        conversationTarget = '@$conversationPartner';
        if (chatState.channels.indexWhere((c) => c.name.toLowerCase() == conversationTarget.toLowerCase()) == -1) {
            chatState.addOrUpdateChannel(Channel(name: conversationTarget, members: []));
        }
      } else {
        conversationTarget = channelName;
      }

      final newMessage = Message.fromJson({
        'from': sender,
        'content': message['text'] ?? '',
        'time': message['time'] ?? DateTime.now().toIso8601String(),
        'id': message['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      });

      chatState.addMessage(conversationTarget, newMessage);
      loadAvatarForUser(sender);
    });
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

  Future<void> handleSendMessage(String text) async {
    if (text.trim().isEmpty) return;

    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }

    final currentConversation = chatState.selectedConversationTarget;
    String target = currentConversation.startsWith('@')
        ? currentConversation.substring(1)
        : currentConversation;

    final sentMessage = Message(
      from: username,
      content: text,
      time: DateTime.now(),
      id: DateTime.now().millisecondsSinceEpoch.toString(),
    );

    chatState.addMessage(currentConversation, sentMessage);
    _webSocketService.sendMessage(target, text);
  }

  Future<void> joinChannel(String channelName) async {
    try {
      await apiService.joinChannel(channelName);
      chatState.selectConversation(channelName);
      chatState.moveChannelToJoined(channelName, username);
      // --- PATCH: Load history for newly joined channel
      await loadChannelHistory(channelName, limit: 100);
    } catch (e) {
      chatState.addInfoMessage('Failed to join channel: $channelName. Error: $e');
    }
  }

  Future<void> partChannel(String channelName) async {
    if (!channelName.startsWith('#')) {
      chatState.addInfoMessage('You can only part public channels.');
      return;
    }
    try {
      // Reverted to use the ApiService for parting channels.
      await apiService.partChannel(channelName);
      // After the API call succeeds, move the channel to the unjoined list.
      chatState.moveChannelToUnjoined(channelName);
    } catch (e) {
      chatState.addInfoMessage('Failed to leave channel: ${e.toString()}');
    }
  }

  Future<void> loadChannelHistory(String channelName, {int limit = 100}) async {
    if (!channelName.startsWith('#')) return;
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
      chatState.addInfoMessage('Failed to load history for $channelName.');
    }
  }

  /// Upload an attachment and return the uploaded URL as a String, or null on error.
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
        chatState.addInfoMessage('Failed to upload attachment: ${jsonResponse['message'] ?? 'Unknown error'}');
        return null;
      }
    } catch (e) {
      chatState.addInfoMessage('Attachment upload failed: $e');
      return null;
    }
  }

  /// The old behavior: upload and immediately send the link as a message (deprecated).
  @Deprecated('Use uploadAttachmentAndGetUrl and let the user send the message with the link.')
  Future<void> uploadAttachment(String filePath) async {
    final url = await uploadAttachmentAndGetUrl(filePath);
    if (url != null) {
      await handleSendMessage(url);
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
          chatState.addInfoMessage('Usage: /join <#channel_name>');
        }
        break;
      case 'part':
        String channelToPart = args.isNotEmpty ? args : chatState.selectedConversationTarget;
        if (channelToPart.isNotEmpty && channelToPart.startsWith('#')) {
          partChannel(channelToPart);
        } else {
          chatState.addInfoMessage('Usage: /part [#channel_name]');
        }
        break;
      default:
        chatState.addInfoMessage('Unknown command: /$command.');
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

  void _handlePendingNotification() {
    if (PendingNotification.channelToNavigateTo != null) {
      final channelName = PendingNotification.channelToNavigateTo!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handleNotificationTap(channelName);
        PendingNotification.channelToNavigateTo = null;
      });
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