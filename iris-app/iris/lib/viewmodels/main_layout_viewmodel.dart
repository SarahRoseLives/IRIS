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
import '../services/fingerprint_service.dart';

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

  bool _userScrolledUp = false;

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

  final FingerprintService _fingerprintService = FingerprintService();

  bool _isAuthenticating = false;

  DateTime? _lastAuthAttempt;

  MainLayoutViewModel({required this.username, this.token}) {
    if (token == null) {
      print("[ViewModel] Error: Token is null. Cannot initialize.");
      _loadingChannels = false;
      _channelError = "Authentication token not found.";
      return;
    }

    chatState = getIt<ChatState>();

    // --- START FINAL FIX: Provide the required 'isAppInBackground' callback ---
    _chatController = ChatController(
      username: username,
      token: token!,
      chatState: chatState,
      isAppInBackground: () => _appLifecycleState != AppLifecycleState.resumed,
    );
    // --- END FINAL FIX ---

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print("[ViewModel] AppLifecycleState changed to: $state");
    _appLifecycleState = state;

    // Trigger your existing resume/pause logic from this central handler
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
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
      final serverChannels = await _chatController.apiService.fetchChannels();
      chatState.mergeChannels(serverChannels);
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomIfUserAtBottom();
    });

    notifyListeners();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final atBottom = (position.maxScrollExtent - position.pixels) <= 50.0;
    _userScrolledUp = !atBottom;
  }

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
              .fetchChannelMessages(channel.name, limit: 100);
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
          return; // Stop fetching more history
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
          return; // Stop fetching more history
        } catch (e) {
          print('Error fetching missed messages for ${channel.name}: $e');
        }
      }
    }
    for (final dm in chatState.dmChannelNames) {
      final messages = chatState.getMessagesForChannel(dm);
      if (messages.isEmpty) {
        try {
          final response =
              await _chatController.apiService.fetchChannelMessages(dm, limit: 100);
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
          return; // Stop fetching more history
        } catch (e) {
          print('Error fetching history for DM $dm: $e');
        }
      } else {
        final lastTime = messages.last.time;
        try {
          final newMessages =
              await _chatController.apiService.fetchMessagesSince(dm, lastTime);
          chatState.addMessageBatch(dm, newMessages);
        } on SessionExpiredException {
          AuthManager.forceLogout(showExpiredMessage: true);
          return; // Stop fetching more history
        } catch (e) {
          print('Error fetching missed messages for DM $dm: $e');
        }
      }
    }
  }

  // --- NEW: App lifecycle handlers for State object to call ---
  void handleAppPaused() {
    _chatController.disconnectWebSocket();
  }

  void handleAppResumed() async {
    if (_isAuthenticating) return;

    if (_lastAuthAttempt != null &&
        DateTime.now().difference(_lastAuthAttempt!).inSeconds < 2) {
      return;
    }

    final fingerprintEnabled =
        await _fingerprintService.isFingerprintEnabled();
    if (fingerprintEnabled) {
      _lastAuthAttempt = DateTime.now();
      _isAuthenticating = true;

      final authenticated = await _fingerprintService.authenticate();

      _isAuthenticating = false;

      if (!authenticated) {
        return;
      }
    }

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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollToBottomIfUserAtBottom() {
    if (_scrollController.hasClients && !_userScrolledUp) {
      _scrollToBottom();
    }
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text;
    if (text.trim().isEmpty) return;
    _msgController.clear();
    await _chatController.handleSendMessage(text);
    _userScrolledUp = false;
    _scrollToBottom();
  }

  void onChannelSelected(String channelName) {
    chatState.selectConversation(channelName);
    notifyListeners();
    NotificationService.getCurrentDMChannel = () {
      final target = chatState.selectedConversationTarget;
      return target.startsWith('@') ? target : null;
    };
    _userScrolledUp = false;
    _scrollToBottom();
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
    _userScrolledUp = false;
    _scrollToBottom();
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
        final updatedChannels = chatState.channels.map((c) {
          if (c.name == channelName) {
            return Channel(
              name: c.name,
              topic: newTopic,
              members: c.members,
            );
          }
          return c;
        }).toList();
        chatState.setChannels(updatedChannels);
      }
    } catch (e) {
      chatState.addSystemMessage(
        selectedConversationTarget,
        'Failed to update topic: ${e.toString()}',
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