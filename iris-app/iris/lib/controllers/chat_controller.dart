import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../main.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import '../models/encryption_session.dart';
import '../models/irc_network.dart';
import '../models/irc_role.dart';
import '../commands/slash_command.dart';
import '../services/api_service.dart';
import '../services/command_handler.dart';
import '../services/encryption_service.dart';
import '../services/notification_service_platform.dart';
import '../services/websocket_service.dart';
import '../config.dart';
import 'chat_state.dart';
import '../viewmodels/main_layout_viewmodel.dart'; // Import MainLayoutViewModel

class ChatController {
  final String username;
  final String token;
  final ChatState chatState;
  final bool Function() isAppInBackground;

  late final ApiService apiService;
  late final WebSocketService wsService;
  late final EncryptionService encryptionService;
  late final NotificationService notificationService;
  late final CommandHandler commandHandler;

  StreamSubscription? _wsMessageSub;
  StreamSubscription? _wsInitialStateSub;
  StreamSubscription? _wsMembersUpdateSub;
  StreamSubscription? _wsEventSub; // For general events from WebSocket

  ChatController({
    required this.username,
    required this.token,
    required this.chatState,
    required this.isAppInBackground,
  }) {
    apiService = GetIt.instance<ApiService>();
    wsService = GetIt.instance<WebSocketService>();
    encryptionService = GetIt.instance<EncryptionService>();
    notificationService = GetIt.instance<NotificationService>();
    commandHandler = CommandHandler();
    commandHandler.registerCommands();

    apiService.setToken(token);
    _listenToWebSocket(); // Listen to WS immediately
  }

  /// Call when the app resumes (enters foreground).
  Future<void> handleAppResumed() async {
    print('[ChatController] App resumed.');
    apiService.setToken(token);
    connectWebSocket();
    notificationService.onAppResumed();
    await processPendingBackgroundMessages();
    await handlePendingNotification();
  }

  /// Call when the app is paused (goes to background).
  void handleAppPaused() {
    print('[ChatController] App paused.');
    notificationService.onAppPaused();
  }

  Stream<WebSocketStatus> get wsStatusStream => wsService.statusStream;
  Stream<String> get errorStream => wsService.errorStream;

  Future<void> initialize() async {
    print('[ChatController] Initializing ChatController...');
    await chatState.loadPersistedMessages();
    await _fetchInitialNetworks();
    connectWebSocket();
    await handlePendingNotification();
    print('[ChatController] ChatController initialization complete.');
  }

  void _listenToWebSocket() {
    print('[ChatController] Setting up WebSocket listeners...');
    _wsMessageSub = wsService.messageStream.listen((data) => _handleIncomingMessage(
          data['channel_name'] as String? ?? '',
          data['sender'] as String? ?? 'Unknown',
          data['text'] as String? ?? '',
          data['time'] as String? ?? DateTime.now().toIso8601String(),
          data['id'] as String? ?? 'msg_${DateTime.now().millisecondsSinceEpoch}',
          data['network_id'] as int? ?? 0,
          data['isEncrypted'] as bool? ?? false,
          data['isSystemInfo'] as bool? ?? false,
          data['isNotice'] as bool? ?? false,
        ));
    _wsInitialStateSub = wsService.initialStateStream.listen(_handleInitialState);
    _wsMembersUpdateSub = wsService.membersUpdateStream.listen(_handleMembersUpdate);
    _wsEventSub = wsService.eventStream.listen(_handleWebSocketEvent);
  }

  void connectWebSocket() {
    print('[ChatController] Requesting WebSocket connection...');
    wsService.connect(token);
  }

  void disconnectWebSocket() {
    print('[ChatController] Requesting WebSocket disconnection...');
    wsService.disconnect();
  }

  void dispose() {
    print('[ChatController] Disposing ChatController...');
    _wsMessageSub?.cancel();
    _wsInitialStateSub?.cancel();
    _wsMembersUpdateSub?.cancel();
    _wsEventSub?.cancel();
    wsService.disconnect();
    print('[ChatController] ChatController disposed.');
  }

  Future<void> _fetchInitialNetworks() async {
    print('[ChatController] Fetching initial IRC networks...');
    try {
      final networks = await apiService.fetchIrcNetworks();
      await chatState.setIrcNetworks(networks);
      print('[ChatController] Successfully fetched ${networks.length} IRC networks.');

      for (final network in networks) {
        for (final channelState in network.channels) {
          final channelIdentifier = "${network.networkName}/${channelState.name}";
          print('[ChatController] Fetching history for $channelIdentifier...');
          try {
            final messages = await apiService.fetchChannelMessages(network.id, channelState.name);
            chatState.addMessageBatch(network.id, channelIdentifier, messages);
            print('[ChatController] Loaded ${messages.length} historical messages for $channelIdentifier');
          } catch (e) {
            chatState.addSystemMessage(network.id, channelIdentifier, "Error loading history for ${channelState.name}: $e");
            print('[ChatController] Error loading history for ${channelState.name}: $e');
          }
        }
      }
      if (chatState.selectedConversationTarget.isEmpty && networks.isNotEmpty) {
        final firstConnectedNetwork = networks.firstWhereOrNull((net) => net.isConnected);
        if (firstConnectedNetwork != null && firstConnectedNetwork.channels.isNotEmpty) {
          final firstChannel = firstConnectedNetwork.channels.first;
          chatState.selectConversation("${firstConnectedNetwork.networkName}/${firstChannel.name}");
        } else if (networks.isNotEmpty && networks.first.channels.isNotEmpty) {
          final firstChannel = networks.first.channels.first;
          chatState.selectConversation("${networks.first.networkName}/${firstChannel.name}");
        } else {
          chatState.addSystemMessage(0, "System", "No channels found. Add a network or join a channel to start chatting.");
        }
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, "System", "Error loading networks: $e");
      print('[ChatController] Error fetching initial networks: $e');
    }
  }

  Future<void> processPendingBackgroundMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingMessagesJson = prefs.getStringList('pending_dm_messages') ?? [];
    await prefs.remove('pending_dm_messages');
    if (pendingMessagesJson.isNotEmpty) {
      print("[ChatController] Processing ${pendingMessagesJson.length} pending background messages...");
    }
    for (var msgJson in pendingMessagesJson) {
      try {
        final Map<String, dynamic> data = jsonDecode(msgJson);
        final String? sender = data['sender'];
        final String? channelNameData = data['channel_name'];
        final String? type = data['type'];

        String channelName = '';
        String networkName = 'Unknown Network';
        int networkId = 0;
        if (type == 'private_message' && sender != null) {
          channelName = '@$sender';
        } else if (channelNameData != null && !channelNameData.startsWith('#')) {
          channelName = '@$channelNameData';
        } else {
          channelName = channelNameData ?? '';
        }

        if (channelName.isEmpty) {
          print("[ChatController] Skipping pending message with empty channelName.");
          continue;
        }

        final existingChannel = chatState.channels.firstWhereOrNull(
          (c) => c.name.toLowerCase() == channelName.toLowerCase(),
        );

        if (existingChannel != null) {
          networkId = existingChannel.networkId;
          networkName = chatState.getNetworkNameForChannel(networkId);
        } else {
          final connectedNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.isConnected);
          if (connectedNetwork != null) {
            networkId = connectedNetwork.id;
            networkName = connectedNetwork.networkName;
            if (channelName.startsWith('@') &&
                !chatState.channels.any((c) => c.networkId == networkId && c.name.toLowerCase() == channelName.toLowerCase())) {
              chatState.addOrUpdateChannel(networkId, Channel(networkId: networkId, name: channelName, members: []));
              chatState.addSystemMessage(networkId, "$networkName/$channelName", "New DM session started with ${channelName.substring(1)}.");
            }
          } else {
            print("[ChatController] No connected networks to associate new message from $sender or $channelName, using networkId 0.");
            chatState.addSystemMessage(0, "$networkName/$channelName", "Received message for unknown network/channel: $channelName.");
          }
        }

        final fullChannelIdentifier = "$networkName/$channelName";

        final message = Message.fromJson({
          'network_id': networkId,
          'sender': data['sender'] ?? 'Unknown',
          'text': data['message'] ?? data['content'] ?? data['body'] ?? '',
          'timestamp': data['time'] ?? DateTime.now().toIso8601String(),
          'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
          'isHistorical': false,
          'isEncrypted': data['is_encrypted'] ?? false,
          'isSystemInfo': data['is_system_info'] ?? false,
          'isNotice': data['is_notice'] ?? false,
          'channel_name': channelName,
        });

        if (message.isEncrypted && message.content.startsWith('[ENC]')) {
          try {
            final decryptedContent = await encryptionService.decryptMessage(message.from, message.content.substring(5));
            if (decryptedContent != null) {
              chatState.addMessage(networkId, channelName, message.copyWith(content: decryptedContent));
              print("[ChatController] Decrypted pending message for $fullChannelIdentifier.");
            } else {
              chatState.addMessage(networkId, channelName, message.copyWith(content: "[Encrypted Message - Failed to decrypt]", isSystemInfo: true));
              print("[ChatController] Failed to decrypt pending message for $fullChannelIdentifier.");
            }
          } catch (e) {
            chatState.addMessage(networkId, channelName, message.copyWith(content: "[Encrypted Message - Decryption Error: $e]", isSystemInfo: true));
            print("[ChatController] Error decrypting pending message: $e");
          }
        } else {
          chatState.addMessage(networkId, channelName, message);
        }
      } catch (e) {
        print("[ChatController] Error processing pending background message: $e");
      }
    }
  }

  Future<void> handlePendingNotification() async {
    await _handlePendingNotification();
  }

  Future<void> _handlePendingNotification() async {
    if (PendingNotification.channelToNavigateTo != null) {
      final targetChannelIdentifier = PendingNotification.channelToNavigateTo!;
      final messageData = PendingNotification.messageData;

      print('[ChatController] Handling pending notification for $targetChannelIdentifier...');

      final parts = targetChannelIdentifier.split('/');
      String networkName = '';
      String rawChannelName = targetChannelIdentifier;
      if (parts.length > 1) {
        networkName = parts[0];
        rawChannelName = parts.skip(1).join('/');
      }

      int networkId = 0;
      final network = chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
      if (network != null) {
        networkId = network.id;
        networkName = network.networkName;
      } else {
        final existingChannel = chatState.channels.firstWhereOrNull((c) => c.name.toLowerCase() == rawChannelName.toLowerCase());
        if (existingChannel != null) {
          networkId = existingChannel.networkId;
          networkName = chatState.getNetworkNameForChannel(networkId);
        } else {
          final connectedNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.isConnected);
          if (connectedNetwork != null) {
            networkId = connectedNetwork.id;
            networkName = connectedNetwork.networkName;
            if (rawChannelName.startsWith('@') &&
                !chatState.channels.any((c) => c.networkId == networkId && c.name.toLowerCase() == rawChannelName.toLowerCase())) {
              chatState.addOrUpdateChannel(networkId, Channel(networkId: networkId, name: rawChannelName, members: []));
              chatState.addSystemMessage(networkId, "$networkName/$rawChannelName", "New DM session started with ${rawChannelName.substring(1)} (from notification).");
            }
          } else {
            print("[ChatController] Could not find or assign network for pending notification channel ($rawChannelName). Using networkId 0.");
            chatState.addSystemMessage(0, targetChannelIdentifier, "Received notification for unknown network/channel: $targetChannelIdentifier.");
          }
        }
      }

      final actualFullChannelIdentifier = "$networkName/$rawChannelName";

      if (messageData != null) {
        final message = Message.fromJson({
          'network_id': networkId,
          'sender': messageData['sender'] ?? 'Unknown',
          'text': messageData['message'] ?? messageData['content'] ?? messageData['body'] ?? '',
          'timestamp': messageData['time'] ?? DateTime.now().toIso8601String(),
          'id': messageData['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
          'isHistorical': false,
          'isEncrypted': messageData['is_encrypted'] ?? false,
          'isSystemInfo': messageData['is_system_info'] ?? false,
          'isNotice': messageData['is_notice'] ?? false,
          'channel_name': rawChannelName,
        });

        if (message.isEncrypted && message.content.startsWith('[ENC]')) {
          try {
            final decryptedContent = await encryptionService.decryptMessage(message.from, message.content.substring(5));
            if (decryptedContent != null) {
              chatState.addMessage(networkId, rawChannelName, message.copyWith(content: decryptedContent));
              print("[ChatController] Decrypted notification message for $actualFullChannelIdentifier.");
            } else {
              chatState.addMessage(networkId, rawChannelName, message.copyWith(content: "[Encrypted Message - Failed to decrypt]", isSystemInfo: true));
              print("[ChatController] Failed to decrypt notification message for $actualFullChannelIdentifier.");
            }
          } catch (e) {
            chatState.addMessage(networkId, rawChannelName, message.copyWith(content: "[Encrypted Message - Decryption Error: $e]", isSystemInfo: true));
            print("[ChatController] Error decrypting notification message: $e");
          }
        } else {
          chatState.addMessage(networkId, rawChannelName, message);
        }
      }

      chatState.selectConversation(actualFullChannelIdentifier);
      PendingNotification.channelToNavigateTo = null;
      PendingNotification.messageData = null;
      print('[ChatController] Navigated to $actualFullChannelIdentifier from notification.');
    }
  }

  Future<void> _handleIncomingMessage(
    String rawChannelName,
    String sender,
    String text,
    String time,
    String id,
    int networkId,
    bool isEncrypted,
    bool isSystemInfo,
    bool isNotice,
  ) async {
    print('[ChatController] Handling incoming message for networkId: $networkId, channel: $rawChannelName from: $sender');

    String networkName = chatState.getNetworkNameForChannel(networkId);
    final String fullChannelIdentifier = "$networkName/$rawChannelName";

    if (!chatState.channels.any((c) => c.networkId == networkId && c.name.toLowerCase() == rawChannelName.toLowerCase())) {
      chatState.addOrUpdateChannel(networkId, Channel(networkId: networkId, name: rawChannelName, members: []));
    }

    String finalContent = text;
    bool messageIsEncrypted = isEncrypted;

    if (isEncrypted && text.startsWith('[ENC]')) {
      try {
        final decryptedText = await encryptionService.decryptMessage(sender, text.substring(5));
        if (decryptedText != null) {
          finalContent = decryptedText;
          chatState.addSystemMessage(networkId, fullChannelIdentifier, "Decrypted message from $sender.");
        } else {
          finalContent = "[Encrypted Message - Failed to decrypt]";
          isSystemInfo = true;
          print("[ChatController] Failed to decrypt message from $sender in $fullChannelIdentifier");
        }
      } catch (e) {
        finalContent = "[Encrypted Message - Decryption Error: $e]";
        isSystemInfo = true;
        print("[ChatController] Error during decryption from $sender in $fullChannelIdentifier: $e");
      }
    } else if (text.startsWith('[ENCRYPTION-REQUEST]')) {
      final requestPayload = text.substring('[ENCRYPTION-REQUEST]'.length).trim();
      try {
        final acceptResponse = await encryptionService.handleEncryptionRequest(sender, requestPayload);
        if (acceptResponse != null) {
          wsService.send({
            'type': 'send_dm',
            'payload': {'target': sender, 'message': acceptResponse, 'network_id': networkId}
          });
          chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.active);
          chatState.addSystemMessage(networkId, fullChannelIdentifier, "Encryption session with $sender is now active.");
          _chatStateChangeQueuedForSafetyNumber = true;
        } else {
          chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.error);
          chatState.addSystemMessage(networkId, fullChannelIdentifier, "Failed to establish encryption with $sender.");
        }
      } catch (e) {
        chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.error);
        chatState.addSystemMessage(networkId, fullChannelIdentifier, "Error handling encryption request from $sender: $e");
        print("[ChatController] Error handling encryption request: $e");
      }
      return;
    } else if (text.startsWith('[ENCRYPTION-ACCEPT]')) {
      final acceptPayload = text.substring('[ENCRYPTION-ACCEPT]'.length).trim();
      try {
        await encryptionService.handleEncryptionAcceptance(sender, acceptPayload);
        chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.active);
        chatState.addSystemMessage(networkId, fullChannelIdentifier, "Encryption session with $sender is now active.");
        _chatStateChangeQueuedForSafetyNumber = true;
      } catch (e) {
        chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.error);
        chatState.addSystemMessage(networkId, fullChannelIdentifier, "Error handling encryption acceptance from $sender: $e");
        print("[ChatController] Error handling encryption acceptance: $e");
      }
      return;
    } else if (text.startsWith('[ENCRYPTION-END]')) {
      encryptionService.endEncryption(sender);
      chatState.setEncryptionStatus(fullChannelIdentifier, EncryptionStatus.none);
      chatState.addSystemMessage(networkId, fullChannelIdentifier, "Encryption session with $sender has ended.");
      return;
    }

    final message = Message(
      networkId: networkId,
      channelName: rawChannelName,
      from: sender,
      content: finalContent,
      time: DateTime.tryParse(time)?.toLocal() ?? DateTime.now(),
      id: id,
      isHistorical: false,
      isEncrypted: messageIsEncrypted,
      isSystemInfo: isSystemInfo,
      isNotice: isNotice,
    );
    chatState.addMessage(networkId, rawChannelName, message);

    if (isAppInBackground() && rawChannelName.startsWith('@')) {
      notificationService.showSimpleNotification(
        title: "New DM from ${message.from}",
        body: message.content,
        payload: {
          'network_id': networkId,
          'channel_name': rawChannelName,
          'sender': message.from,
          'message': message.content,
          'type': 'private_message',
        },
      );
    }
  }

  void _handleInitialState(dynamic state) {
    print('[ChatController] Handling initial state...');
    try {
      final List<dynamic> networksData = state['networks'] ?? [];
      final List<IrcNetwork> newNetworks = networksData.map((n) => IrcNetwork.fromJson(n as Map<String, dynamic>)).toList();
      chatState.setIrcNetworks(newNetworks);
      print('[ChatController] Initial state processed: ${newNetworks.length} networks loaded.');
      for (final network in newNetworks) {
        for (final channelState in network.channels) {
          final channelIdentifier = "${network.networkName}/${channelState.name}";
          print('[ChatController] Fetching initial history for $channelIdentifier...');
          apiService.fetchChannelMessages(network.id, channelState.name).then((messages) {
            chatState.addMessageBatch(network.id, channelIdentifier, messages);
            print('[ChatController] Loaded ${messages.length} historical messages for $channelIdentifier');
          }).catchError((e) {
            chatState.addSystemMessage(network.id, channelIdentifier, "Error loading initial history for ${channelState.name}: $e");
            print('[ChatController] Error loading initial history for ${channelState.name}: $e');
          });
        }
      }
      if (chatState.selectedConversationTarget.isEmpty) {
        final firstConnectedNetwork = newNetworks.firstWhereOrNull((net) => net.isConnected);
        if (firstConnectedNetwork != null && firstConnectedNetwork.channels.isNotEmpty) {
          final firstChannel = firstConnectedNetwork.channels.first;
          chatState.selectConversation("${firstConnectedNetwork.networkName}/${firstChannel.name}");
          print('[ChatController] Selected initial conversation: ${firstConnectedNetwork.networkName}/${firstChannel.name}');
        } else if (newNetworks.isNotEmpty && newNetworks.first.channels.isNotEmpty) {
          final firstChannel = newNetworks.first.channels.first;
          chatState.selectConversation("${newNetworks.first.networkName}/${firstChannel.name}");
          print('[ChatController] Selected initial conversation: ${newNetworks.first.networkName}/${firstChannel.name}');
        } else {
          chatState.addSystemMessage(0, "System", "No channels found. Add a network or join a channel to start chatting.");
        }
      }
    } catch (e) {
      print('[ChatController] Error processing initial state: $e');
      chatState.addSystemMessage(0, "System", "Error processing initial state from server: $e");
    }
  }

  void _handleMembersUpdate(dynamic update) {
    print('[ChatController] Handling members update: $update');
    try {
      final int networkId = update['network_id'];
      final String channelName = update['channel'];
      final List<dynamic> membersData = update['members'];

      final network = chatState.ircNetworks.firstWhereOrNull((net) => net.id == networkId);
      if (network == null) {
        print("[ChatController] Members update: Network with ID $networkId not found.");
        return;
      }

      final updatedChannels = network.channels.map((channelState) {
        if (channelState.name.toLowerCase() == channelName.toLowerCase()) {
          final List<ChannelMember> newMembers = membersData.map((m) => ChannelMember.fromJson(m)).toList();
          return channelState.copyWith(members: newMembers);
        }
        return channelState;
      }).toList();

      chatState.updateIrcNetwork(network.copyWith(channels: updatedChannels));
      print('[ChatController] Members updated for ${network.networkName}/$channelName.');
    } catch (e) {
      print('[ChatController] Error processing members update: $e');
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error updating members: $e");
    }
  }

  bool _chatStateChangeQueuedForSafetyNumber = false;

  Future<void> _handleWebSocketEvent(Map<String, dynamic> event) async {
    final String eventType = event['type'];
    final Map<String, dynamic> payload = event['payload'] ?? {};

    final int networkId = payload['network_id'] as int? ?? 0;
    final String rawChannelName = payload['channel'] as String? ?? payload['channel_name'] as String? ?? '';
    final String networkName = chatState.getNetworkNameForChannel(networkId);
    final String fullChannelIdentifier = "$networkName/$rawChannelName";

    print("[ChatController] Handling WebSocket event: $eventType for $fullChannelIdentifier");

    switch (eventType) {
      case 'network_connect':
        final int connectedNetworkId = payload['network_id'] as int? ?? 0;
        final String connectedNetworkName = payload['network_name'] as String? ?? 'Unknown Network';
        final String nickname = payload['nickname'] as String? ?? '';
        final existingNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.id == connectedNetworkId);
        if (existingNetwork != null) {
          final updatedNetwork = existingNetwork.copyWith(isConnected: true, nickname: nickname);
          chatState.updateIrcNetwork(updatedNetwork);
          chatState.addSystemMessage(connectedNetworkId, "$connectedNetworkName/$nickname", "Connected to '$connectedNetworkName' as $nickname.");
        }
        break;

      case 'network_disconnect':
        final int disconnectedNetworkId = payload['network_id'] as int? ?? 0;
        final String disconnectedNetworkName = payload['network_name'] as String? ?? 'Unknown Network';
        final existingNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.id == disconnectedNetworkId);
        if (existingNetwork != null) {
          // --- FIX ---
          // Update the connection status but DO NOT clear the channel list.
          final updatedNetwork = existingNetwork.copyWith(isConnected: false);
          // --- END FIX ---
          chatState.updateIrcNetwork(updatedNetwork);
          chatState.addSystemMessage(disconnectedNetworkId, "$disconnectedNetworkName/System", "Disconnected from '$disconnectedNetworkName'.");
          // Optional: Consider removing the navigation change so the user can see the disconnected state without being kicked out of the view.
          // if (chatState.selectedConversationTarget.startsWith("$disconnectedNetworkName/")) {
          //   GetIt.instance<MainLayoutViewModel>().selectMainView();
          // }
        }
        break;

      case 'channel_join':
        final String joinedChannelName = payload['name'] as String? ?? '';
        final String joinedNick = payload['user'] as String? ?? '';
        final int joinNetworkId = payload['network_id'] as int? ?? 0;
        final String joinNetworkName = chatState.getNetworkNameForChannel(joinNetworkId);
        final String joinIdentifier = "$joinNetworkName/$joinedChannelName";

        final existingNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.id == joinNetworkId);
        if (existingNetwork != null) {
          final existingChannel = existingNetwork.channels.firstWhereOrNull((c) => c.name.toLowerCase() == joinedChannelName.toLowerCase());

          final List<NetworkChannelState> updatedChannels = List.from(existingNetwork.channels);

          if (existingChannel == null) {
            updatedChannels.add(NetworkChannelState(name: joinedChannelName, topic: '', members: [], lastUpdate: DateTime.now(), isConnected: true));
          }

          final updatedNetwork = existingNetwork.copyWith(channels: updatedChannels);
          chatState.updateIrcNetwork(updatedNetwork);
        }

        chatState.addSystemMessage(joinNetworkId, joinIdentifier, "$joinedNick has joined $joinedChannelName.");
        chatState.selectConversation(joinIdentifier);
        break;

      case 'channel_part':
        final String partedChannelName = payload['name'] as String? ?? '';
        final String partedNick = payload['user'] as String? ?? '';
        final int partNetworkId = payload['network_id'] as int? ?? 0;
        final String partNetworkName = chatState.getNetworkNameForChannel(partNetworkId);
        final String partIdentifier = "$partNetworkName/$partedChannelName";

        final existingNetwork = chatState.ircNetworks.firstWhereOrNull((net) => net.id == partNetworkId);
        if (existingNetwork != null) {
          if (partedNick.toLowerCase() == existingNetwork.nickname.toLowerCase()) {
            final updatedChannels = List.of(existingNetwork.channels)..removeWhere((c) => c.name.toLowerCase() == partedChannelName.toLowerCase());
            final updatedNetwork = existingNetwork.copyWith(channels: updatedChannels);
            chatState.updateIrcNetwork(updatedNetwork);
            if (chatState.selectedConversationTarget.toLowerCase() == partIdentifier.toLowerCase()) {
              GetIt.instance<MainLayoutViewModel>().selectMainView();
            }
          }
        }
        chatState.addSystemMessage(partNetworkId, partIdentifier, "$partedNick has left $partedChannelName.");
        break;

      case 'network_member_list':
      case 'members_update':
        print('[ChatController] Received members_update event. Delegating to _handleMembersUpdate.');
        _handleMembersUpdate({
          'network_id': payload['network_id'],
          'channel': payload['channel_name'],
          'members': payload['members'],
        });
        break;

      case 'topic_change':
        final topicChannelName = payload['channel'] as String? ?? '';
        final newTopic = payload['topic'] as String? ?? '';
        final setBy = payload['set_by'] as String? ?? 'System';
        final topicNetworkId = payload['network_id'] as int? ?? 0;

        final networkToUpdate = chatState.ircNetworks.firstWhereOrNull((n) => n.id == topicNetworkId);
        if (networkToUpdate != null) {
          final channelIndex = networkToUpdate.channels.indexWhere((c) => c.name.toLowerCase() == topicChannelName.toLowerCase());
          if (channelIndex != -1) {
            final updatedChannel = networkToUpdate.channels[channelIndex].copyWith(topic: newTopic);
            final updatedChannels = List.of(networkToUpdate.channels);
            updatedChannels[channelIndex] = updatedChannel;
            chatState.updateIrcNetwork(networkToUpdate.copyWith(channels: updatedChannels));
          }
        }

        final topicIdentifier = "${chatState.getNetworkNameForChannel(topicNetworkId)}/$topicChannelName";
        chatState.addSystemMessage(topicNetworkId, topicIdentifier, "Topic for $topicChannelName set by $setBy: $newTopic");
        break;

      default:
        print("[ChatController] Unhandled WebSocket event type: $eventType, payload: $payload");
        chatState.addSystemMessage(networkId, fullChannelIdentifier, "Received unhandled server event: $eventType");
        break;
    }
  }

  Future<void> handleSendMessage(String text) async {
    final target = chatState.selectedConversationTarget;
    final parts = target.split('/');
    if (parts.length < 2) {
      chatState.addSystemMessage(0, target, "Cannot send message: No channel selected.");
      return;
    }
    final networkName = parts[0];
    final rawChannelName = parts.skip(1).join('/');

    final network = chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
    if (network == null) {
      chatState.addSystemMessage(0, target, "Cannot send message: Network '$networkName' not found.");
      return;
    }
    final networkId = network.id;

    if (text.startsWith('/')) {
      await commandHandler.handleCommand(text, this);
    } else {
      String? messageToSend = text;
      bool isEncrypted = false;
      if (rawChannelName.startsWith('@') && chatState.getEncryptionStatus(target) == EncryptionStatus.active) {
        try {
          messageToSend = await encryptionService.encryptMessage(rawChannelName.substring(1), text);
          isEncrypted = true;
          if (messageToSend == null) {
            chatState.addSystemMessage(networkId, target, "Failed to encrypt message: encryption session not ready.");
            return;
          }
        } catch (e) {
          chatState.addSystemMessage(networkId, target, "Failed to encrypt message: $e");
          return;
        }
      }

      final message = Message(
        networkId: networkId,
        channelName: rawChannelName,
        from: username,
        content: text,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        isEncrypted: isEncrypted,
      );
      chatState.addMessage(networkId, rawChannelName, message);

      if (rawChannelName.startsWith('#')) {
        wsService.sendMessage(networkId, rawChannelName, messageToSend!);
      } else if (rawChannelName.startsWith('@')) {
        wsService.send({
          'type': 'send_dm',
          'payload': {
            'network_id': networkId,
            'target': rawChannelName.substring(1),
            'message': messageToSend!,
            'is_encrypted': isEncrypted,
          }
        });
      }
    }
  }

  Future<void> joinChannel(String channelIdentifier) async {
    final parts = channelIdentifier.split('/');
    if (parts.length < 2) {
      chatState.addSystemMessage(0, channelIdentifier, "Invalid channel identifier to join.");
      return;
    }
    final networkName = parts[0];
    final rawChannelName = parts.skip(1).join('/');

    final network = chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
    if (network == null) {
      chatState.addSystemMessage(0, channelIdentifier, "Network '$networkName' not found.");
      return;
    }
    final networkId = network.id;

    try {
      chatState.addSystemMessage(networkId, channelIdentifier, "Attempting to join $rawChannelName...");
      await apiService.joinChannel(networkId, rawChannelName);
      chatState.selectConversation(channelIdentifier);
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(networkId, channelIdentifier, "Failed to join $rawChannelName: $e");
    }
  }

  Future<void> partChannel(String channelIdentifier) async {
    final parts = channelIdentifier.split('/');
    if (parts.length < 2) {
      chatState.addSystemMessage(0, channelIdentifier, "Invalid channel identifier to part.");
      return;
    }
    final networkName = parts[0];
    final rawChannelName = parts.skip(1).join('/');

    final network = chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
    if (network == null) {
      chatState.addSystemMessage(0, channelIdentifier, "Network '$networkName' not found.");
      return;
    }
    final networkId = network.id;

    try {
      chatState.addSystemMessage(networkId, channelIdentifier, "Attempting to part $rawChannelName...");
      await apiService.partChannel(networkId, rawChannelName);
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(networkId, channelIdentifier, "Failed to part $rawChannelName: $e");
    }
  }

  IrcRole getCurrentUserRoleInChannel(String channelIdentifier) {
    final parts = channelIdentifier.split('/');
    if (parts.length < 2) return IrcRole.user;

    final networkName = parts[0];
    final rawChannelName = parts.skip(1).join('/');

    final network = chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
    if (network == null) return IrcRole.user;

    final channelState = network.channels.firstWhereOrNull((c) => c.name.toLowerCase() == rawChannelName.toLowerCase());
    if (channelState == null) return IrcRole.user;

    final member = channelState.members.firstWhereOrNull((m) => m.nick.toLowerCase() == username.toLowerCase());
    if (member == null) return IrcRole.user;

    switch (member.prefix) {
      case '~':
        return IrcRole.owner;
      case '&':
        return IrcRole.admin;
      case '@':
        return IrcRole.op;
      case '%':
        return IrcRole.halfOp;
      case '+':
        return IrcRole.voiced;
      default:
        return IrcRole.user;
    }
  }

  Future<String?> uploadAttachmentAndGetUrl(String filePath) async {
    try {
      File file = File(filePath);
      return await apiService.uploadAttachmentAndGetUrl(file);
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
      return null;
    } catch (e) {
      print("Error uploading attachment: $e");
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to upload attachment: $e");
      return null;
    }
  }

  Future<void> loadAvatarForUser(String nick) async {
    if (chatState.hasAvatar(nick)) return;

    if (nick.toLowerCase() == gatewayNick.toLowerCase()) {
      chatState.setAvatar(nick, 'assets/gateway_bot_avatar.png');
      return;
    }

    final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
    String? foundUrl;

    for (final ext in possibleExtensions) {
      final String potentialAvatarUrl = '$baseSecureUrl/avatars/$nick$ext';
      try {
        final response = await http.head(Uri.parse(potentialAvatarUrl));
        if (response.statusCode == 200) {
          foundUrl = potentialAvatarUrl;
          break;
        }
      } catch (_) {}
    }
    chatState.setAvatar(nick, foundUrl ?? '');
  }

  Future<void> initiateOrEndEncryption() async {
    final currentTarget = chatState.selectedConversationTarget;
    final rawTarget = currentTarget.split('/').last;
    if (!rawTarget.startsWith('@')) {
      chatState.addSystemMessage(0, currentTarget, "Encryption is only available for Direct Messages.");
      return;
    }
    final dmTargetUser = rawTarget.substring(1);

    final currentStatus = chatState.getEncryptionStatus(currentTarget);

    final network = chatState.ircNetworks.firstWhereOrNull((net) => currentTarget.startsWith("${net.networkName}/"));
    final networkId = network?.id ?? 0;

    if (currentStatus == EncryptionStatus.active || currentStatus == EncryptionStatus.pending) {
      chatState.addSystemMessage(networkId, currentTarget, "Attempting to end encryption with $dmTargetUser...");
      final endMessage = encryptionService.endEncryption(dmTargetUser);
      wsService.send({
        'type': 'send_dm',
        'payload': {
          'network_id': networkId,
          'target': dmTargetUser,
          'message': endMessage,
          'is_encrypted': false,
        }
      });
      chatState.setEncryptionStatus(currentTarget, EncryptionStatus.none);
      chatState.addSystemMessage(networkId, currentTarget, "Encryption session ended.");
    } else {
      chatState.addSystemMessage(networkId, currentTarget, "Initiating encryption with $dmTargetUser...");
      chatState.setEncryptionStatus(currentTarget, EncryptionStatus.pending);
      try {
        final request = await encryptionService.initiateEncryption(dmTargetUser);
        if (request != null) {
          wsService.send({
            'type': 'send_dm',
            'payload': {
              'network_id': networkId,
              'target': dmTargetUser,
              'message': request,
              'is_encrypted': false,
            }
          });
          chatState.addSystemMessage(
            networkId,
            currentTarget,
            "Encryption request sent to $dmTargetUser. Waiting for acceptance...",
          );
        } else {
          chatState.addSystemMessage(
            networkId,
            currentTarget,
            "Failed to initiate encryption. Check logs or try again.",
          );
          chatState.setEncryptionStatus(currentTarget, EncryptionStatus.error);
        }
      } catch (e) {
        chatState.addSystemMessage(
          networkId,
          currentTarget,
          "Error initiating encryption: $e",
        );
        chatState.setEncryptionStatus(currentTarget, EncryptionStatus.error);
      }
    }
  }

  bool get shouldShowSafetyNumberDialogAfterStatusChange => _chatStateChangeQueuedForSafetyNumber;
  void didShowSafetyNumberDialog() {
    _chatStateChangeQueuedForSafetyNumber = false;
  }

  Future<String?> getSafetyNumberForTarget() async {
    final currentTarget = chatState.selectedConversationTarget;
    final rawTarget = currentTarget.split('/').last;
    if (!rawTarget.startsWith('@')) {
      return null;
    }
    final dmTargetUser = rawTarget.substring(1);
    return await encryptionService.getSafetyNumber(dmTargetUser);
  }

  Future<void> setMyPronouns(String pronouns) async {
    try {
      wsService.send({
        'type': 'set_pronouns',
        'payload': {'pronouns': pronouns},
      });
      chatState.setUserPronouns(username, pronouns);
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Your pronouns set to: '$pronouns'.");
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to set pronouns: $e");
    }
  }

  List<SlashCommand> getAvailableCommandsForRole(IrcRole userRole) {
    return commandHandler.getAvailableCommandsForRole(userRole);
  }

  Future<void> addIrcNetwork(IrcNetwork network) async {
    try {
      final response = await apiService.addIrcNetwork(network);
      if (response['success'] == true) {
        await _fetchInitialNetworks();
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Network '${network.networkName}' added successfully.");
      } else {
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to add network: ${response['message'] ?? 'Unknown error'}");
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error adding network: $e");
    }
  }

  Future<void> updateIrcNetwork(IrcNetwork network) async {
    try {
      final response = await apiService.updateIrcNetwork(network);
      if (response['success'] == true) {
        await _fetchInitialNetworks();
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Network '${network.networkName}' updated successfully.");
      } else {
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to update network: ${response['message'] ?? 'Unknown error'}");
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error updating network: $e");
    }
  }

  Future<void> deleteIrcNetwork(int networkId) async {
    try {
      final networkName = chatState.ircNetworks.firstWhereOrNull((net) => net.id == networkId)?.networkName ?? "Unknown Network";
      final response = await apiService.deleteIrcNetwork(networkId);
      if (response['success'] == true) {
        chatState.removeIrcNetwork(networkId);
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Network '$networkName' deleted successfully.");
        final currentSelectedNetworkId = chatState.selectedChannel?.networkId;
        if (currentSelectedNetworkId == null || currentSelectedNetworkId == networkId) {
          GetIt.instance<MainLayoutViewModel>().selectMainView();
        }
      } else {
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to delete network: ${response['message'] ?? 'Unknown error'}");
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error deleting network: $e");
    }
  }

  Future<void> connectIrcNetwork(int networkId) async {
    try {
      final networkName = chatState.ircNetworks.firstWhereOrNull((net) => net.id == networkId)?.networkName ?? "Unknown Network";
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Attempting to connect to network '$networkName'...");
      final response = await apiService.connectIrcNetwork(networkId);
      if (response['success'] == true) {
        final String nickname = response['nickname'] ?? username;
        chatState.addSystemMessage(networkId, "$networkName/$nickname", "Connection request sent for '$networkName'. Waiting for server response...");
      } else {
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to connect to network '$networkName': ${response['message'] ?? 'Unknown error'}");
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error connecting to network: $e");
    }
  }

  Future<void> disconnectIrcNetwork(int networkId) async {
    try {
      final networkName = chatState.ircNetworks.firstWhereOrNull((net) => net.id == networkId)?.networkName ?? "Unknown Network";
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Attempting to disconnect from network '$networkName'...");
      final response = await apiService.disconnectIrcNetwork(networkId);
      if (response['success'] == true) {
        chatState.addSystemMessage(networkId, chatState.selectedConversationTarget, "Disconnection request sent for '$networkName'.");
      } else {
        chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Failed to disconnect from network '$networkName': ${response['message'] ?? 'Unknown error'}");
      }
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      chatState.addSystemMessage(0, chatState.selectedConversationTarget, "Error disconnecting from network: $e");
    }
  }

  void sendRawWebSocketMessage(Map<String, dynamic> message) {
    wsService.send(message);
  }
}