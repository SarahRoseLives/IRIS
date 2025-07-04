import 'package:flutter/material.dart';
import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart'; // Needed for kIsWeb

import '../main.dart'; // Provides AuthManager
import '../services/api_service.dart'; // Provides SessionExpiredException

import '../services/websocket_service.dart';
import '../services/notification_service_platform.dart';
import 'chat_state.dart';
import 'chat_controller.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/encryption_session.dart';
import '../commands/slash_command.dart'; // Import for commands
import '../models/irc_role.dart';

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver {
  // State and Controller
  late final ChatState chatState;
  late final ChatController _chatController;

  // Dependencies
  final String username;
  final String? token;

  // UI-specific State
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;
  bool _unjoinedChannelsExpanded = false;
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _wsStatusSub;
  StreamSubscription? _errorSub;

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  bool _shouldShowSafetyNumberDialog = false;

  final Set<String> _blockedUsers = {};
  final Set<String> _hiddenMessageIds = {};

  // START OF CHANGE: Fix for chat bouncing issue
  bool _userScrolledUp = false;
  // END OF CHANGE

  Set<String> get blockedUsers => _blockedUsers;
  Set<String> get hiddenMessageIds => _hiddenMessageIds;

  void blockUser(String username) {
    _blockedUsers.add(username);
    notifyListeners();
  }

  void unblockUser(String username) {
    _blockedUsers.remove(username);
    notifyListeners();
  }

  void hideMessage(String messageId) {
    _hiddenMessageIds.add(messageId);
    notifyListeners();
  }

  void unhideMessage(String messageId) {
    _hiddenMessageIds.remove(messageId);
    notifyListeners();
  }

  MainLayoutViewModel({required this.username, this.token}) {
    if (token == null) {
      print("[ViewModel] Error: Token is null. Cannot initialize.");
      _loadingChannels = false;
      _channelError = "Authentication token not found.";
      return;
    }

    chatState = getIt<ChatState>();

    _chatController = ChatController(
      username: username,
      token: token!,
      chatState: chatState,
      isAppInBackground: () => _appLifecycleState != AppLifecycleState.resumed,
    );

    NotificationService.getCurrentDMChannel = () {
      final target = chatState.selectedConversationTarget;
      return target.startsWith('@') ? target : null;
    };

    _scrollController.addListener(_onScroll);

    _initialize();
  }

  // --- GETTERS ---
  AppLifecycleState get appLifecycleState => _appLifecycleState;
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  WebSocketStatus get wsStatus => _wsStatus;
  bool get unjoinedChannelsExpanded => _unjoinedChannelsExpanded;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;
  List<Message> get currentChannelMessages =>
      chatState.messagesForSelectedChannel;
  String get selectedConversationTarget => chatState.selectedConversationTarget;
  List<ChannelMember> get members => chatState.membersForSelectedChannel;
  Map<String, String> get userAvatars => chatState.userAvatars;
  Map<String, String> get userPronouns => chatState.userPronouns;
  List<String> get joinedPublicChannelNames =>
      chatState.joinedPublicChannelNames;
  List<String> get unjoinedPublicChannelNames =>
      chatState.unjoinedPublicChannelNames;
  List<String> get dmChannelNames => chatState.dmChannelNames;
  EncryptionStatus get currentEncryptionStatus =>
      chatState.getEncryptionStatus(selectedConversationTarget);
  bool get shouldShowSafetyNumberDialog => _shouldShowSafetyNumberDialog;
  bool hasUnreadMessages(String channelName) =>
      chatState.hasUnreadMessages(channelName);
  Message? getLastMessage(String channelName) =>
      chatState.getLastMessage(channelName);

  // START OF CHANGE: Getter for available slash commands
  List<SlashCommand> get availableCommands {
    final IrcRole userRole =
        _chatController.getCurrentUserRoleInChannel(selectedConversationTarget);
    return _chatController.getAvailableCommandsForRole(userRole);
  }
  // END OF CHANGE

  bool get hasUnreadDms {
    for (final dmName in dmChannelNames) {
      if (hasUnreadMessages(dmName)) {
        final lastMessage = getLastMessage(dmName);
        if (lastMessage != null && lastMessage.from != username) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("[ViewModel] AppLifecycleState changed to: $state");
    _appLifecycleState = state;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      handleAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      handleAppResumed();
    }
    notifyListeners();
  }

  void _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    chatState.addListener(_onChatStateChanged);
    _wsStatusSub = _chatController.wsStatusStream.listen(_onWsStatusChanged);
    _errorSub = _chatController.errorStream.listen(_onErrorChanged);
    await _chatController.initialize();
    _loadingChannels = true;
    notifyListeners();
    try {
      // 1. First, get the authoritative channel list from the server
      final serverChannels = await _chatController.apiService.fetchChannels();
      chatState.mergeChannels(serverChannels);

      // 2. NOW, process any pending messages that arrived when the app was closed.
      // This adds the new DM channel to the now-stable list.
      await _chatController.processPendingBackgroundMessages();

      // 3. Finally, connect to the WebSocket.
      _chatController.connectWebSocket();
    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      _channelError = "Failed to load conversations: $e";
    } finally {
      _loadingChannels = false;
      await _fetchLatestHistoryForAllChannels();
      final allNicks = <String>{};
      for (final channel in chatState.channels) {
        for (final member in channel.members) {
          allNicks.add(member.nick);
        }
        if (channel.name.startsWith('@')) {
          allNicks.add(channel.name.substring(1));
        }
        for (final msg in chatState.getMessagesForChannel(channel.name)) {
          allNicks.add(msg.from);
        }
      }
      for (final nick in allNicks) {
        _chatController.loadAvatarForUser(nick);
      }
      notifyListeners();
    }
  }

  void _onChatStateChanged() {
    final currentStatus =
        chatState.getEncryptionStatus(selectedConversationTarget);
    if (currentStatus == EncryptionStatus.active &&
        !_shouldShowSafetyNumberDialog) {
      final messages = chatState.messagesForSelectedChannel;
      if (messages.isNotEmpty) {
        final lastMessage = messages.last;
        if (lastMessage.isSystemInfo &&
            lastMessage.content.contains('Session is now active')) {
          _shouldShowSafetyNumberDialog = true;
        }
      }
    }

    // START OF CHANGE: Chat bounce fix
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToTopIfAtBottom();
    });
    // END OF CHANGE

    notifyListeners();
  }

  // START OF CHANGE: Chat bounce fix
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // "At the bottom" of the chat now means scrolled to the top of the reversed list.
    final atBottom = position.pixels <= 50.0;
    if (atBottom != !_userScrolledUp) {
      _userScrolledUp = !atBottom;
    }
  }
  // END OF CHANGE

  void _onWsStatusChanged(WebSocketStatus status) {
    if (status == WebSocketStatus.connected) {
      _loadingChannels = false;
      _channelError = null;
      _fetchLatestHistoryForAllChannels();
      _checkForPendingNotifications();
    } else {
      _loadingChannels = status == WebSocketStatus.connecting;
    }
    _wsStatus = status;
    notifyListeners();
  }

  void _checkForPendingNotifications() {}

  void _onErrorChanged(String? error) {
    _channelError = error;
    _loadingChannels = false;
    notifyListeners();
  }

  Future<void> _fetchLatestHistoryForAllChannels() async {
    for (final channel in chatState.channels) {
      if (!channel.name.startsWith('#')) continue;
      final messages = chatState.getMessagesForChannel(channel.name);
      if (messages.isEmpty) {
        try {
          final response = await _chatController.apiService
              .fetchChannelMessages(channel.name, limit: 2500);
          final newMessages = response
              .map((item) => Message.fromJson({
                    ...item,
                    'isHistorical': true,
                    'id': item['id'] ?? 'hist-${item['time']}-${item['from']}',
                  }))
              .toList();
          chatState.addMessageBatch(channel.name, newMessages);
        } on SessionExpiredException {
          AuthManager.forceLogout(showExpiredMessage: true);
          return;
        } catch (e) {
          print('Error fetching history for ${channel.name}: $e');
        }
      } else {
        final lastTime = messages.last.time;
        try {
          final newMessages = await _chatController.apiService
              .fetchMessagesSince(channel.name, lastTime);
          chatState.addMessageBatch(channel.name, newMessages);
        } on SessionExpiredException {
          AuthManager.forceLogout(showExpiredMessage: true);
          return;
        } catch (e) {
          print('Error fetching missed messages for ${channel.name}: $e');
        }
      }
    }
    for (final dm in chatState.dmChannelNames) {
      final messages = chatState.getMessagesForChannel(dm);
      if (messages.isEmpty) {
        try {
          final response = await _chatController.apiService
              .fetchChannelMessages(dm, limit: 2500);
          if (response.isNotEmpty) {
            if (!chatState.channels.any((c) => c.name == dm)) {
              chatState.addOrUpdateChannel(Channel(
                name: dm,
                members: [],
              ));
            }
          }
          final newMessages = response
              .map((item) => Message.fromJson({
                    ...item,
                    'isHistorical': true,
                    'id': item['id'] ?? 'hist-${item['time']}-${item['from']}',
                    'channel_name': dm,
                  }))
              .toList();
          chatState.addMessageBatch(dm, newMessages);
        } on SessionExpiredException {
          AuthManager.forceLogout(showExpiredMessage: true);
          return;
        } catch (e) {
          print('Error fetching history for DM $dm: $e');
        }
      } else {
        final lastTime = messages.last.time;
        try {
          final newMessages = await _chatController.apiService
              .fetchMessagesSince(dm, lastTime);
          chatState.addMessageBatch(dm, newMessages);
        } on SessionExpiredException {
          AuthManager.forceLogout(showExpiredMessage: true);
          return;
        } catch (e) {
          print('Error fetching missed messages for DM $dm: $e');
        }
      }
    }
  }

  void handleAppPaused() {
    _chatController.disconnectWebSocket();
  }

  void handleAppResumed() {
    _chatController.connectWebSocket();
    _fetchLatestHistoryForAllChannels();
  }

  void toggleEncryption() {
    _chatController.initiateOrEndEncryption();
  }

  Future<String?> getSafetyNumber() {
    return _chatController.getSafetyNumberForTarget();
  }

  void didShowSafetyNumberDialog() {
    _shouldShowSafetyNumberDialog = false;
  }

  void toggleLeftDrawer() {
    if (kIsWeb) {
      _showLeftDrawer = !_showLeftDrawer;
    } else {
      _showLeftDrawer = !_showLeftDrawer;
      if (_showLeftDrawer) _showRightDrawer = false;
    }
    notifyListeners();
  }

  void toggleRightDrawer() {
    if (kIsWeb) {
      _showRightDrawer = !_showRightDrawer;
    } else {
      _showRightDrawer = !_showRightDrawer;
      if (_showRightDrawer) _showLeftDrawer = false;
    }
    notifyListeners();
  }

  void toggleUnjoinedChannelsExpanded() {
    _unjoinedChannelsExpanded = !_unjoinedChannelsExpanded;
    notifyListeners();
  }

  // START OF CHANGE: Chat bounce fix (renamed methods)
  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0, // Top of the reversed list
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollToTopIfAtBottom() {
    if (_scrollController.hasClients && !_userScrolledUp) {
      _scrollToTop();
    }
  }
  // END OF CHANGE

  Future<void> handleSendMessage() async {
    final text = _msgController.text;
    if (text.trim().isEmpty) return;
    _msgController.clear();
    await _chatController.handleSendMessage(text);
    // START OF CHANGE: Chat bounce fix
    _userScrolledUp = false;
    _scrollToTop();
    // END OF CHANGE
  }

  Future<void> setMyPronouns(String pronouns) async {
    await _chatController.setMyPronouns(pronouns);
  }

  void onChannelSelected(String channelName) {
    chatState.selectConversation(channelName);
    notifyListeners();
    NotificationService.getCurrentDMChannel = () {
      final target = chatState.selectedConversationTarget;
      return target.startsWith('@') ? target : null;
    };
    // START OF CHANGE: Chat bounce fix
    _userScrolledUp = false;
    _scrollToTop();
    // END OF CHANGE
  }

  void onUnjoinedChannelTap(String channelName) =>
      _chatController.joinChannel(channelName);
  void onDmSelected(String dmChannelName) => onChannelSelected(dmChannelName);
  void partChannel(String channelName) =>
      _chatController.partChannel(channelName);

  void selectMainView() {
    final index = chatState.channels.indexWhere((c) => c.name.startsWith('#'));
    if (index != -1) {
      onChannelSelected(chatState.channels[index].name);
    } else if (chatState.channels.isNotEmpty) {
      onChannelSelected(chatState.channels[0].name);
    }
  }

  Future<String?> uploadAttachmentAndGetUrl(String filePath) async {
    return await _chatController.uploadAttachmentAndGetUrl(filePath);
  }

  void startNewDM(String username) {
    String channelName = '@${username.trim()}';
    if (!chatState.channels.any((c) => c.name == channelName)) {
      chatState.addOrUpdateChannel(Channel(
        name: channelName,
        members: [],
      ));
    }
    chatState.selectConversation(channelName);
    notifyListeners();
    // START OF CHANGE: Chat bounce fix
    _userScrolledUp = false;
    _scrollToTop();
    // END OF CHANGE
  }

  void removeDmMessage(Message message) {
    chatState.removeDmMessage(message);
  }

  void removeDmChannel(String dmChannelName) {
    if (selectedConversationTarget == dmChannelName) {
      selectMainView();
    }
    chatState.removeDmChannel(dmChannelName);
    notifyListeners();
  }

  Future<void> updateChannelTopic(String newTopic) async {
    try {
      final channelName = selectedConversationTarget;
      if (channelName.startsWith('#')) {
        _chatController.sendRawWebSocketMessage({
          'type': 'topic_change',
          'payload': {
            'channel': channelName,
            'topic': newTopic,
          },
        });
      }
    } catch (e) {
      chatState.addSystemMessage(
        selectedConversationTarget,
        'Failed to send topic update request: ${e.toString()}',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatState.removeListener(_onChatStateChanged);
    _wsStatusSub?.cancel();
    _errorSub?.cancel();

    if (_wsStatus == WebSocketStatus.connected) {
      _chatController.disconnectWebSocket();
    }

    _scrollController.removeListener(_onScroll);
    _chatController.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}