import 'package:flutter/material.dart';
import 'dart:async';

import '../services/websocket_service.dart';
import 'chat_state.dart';
import 'chat_controller.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';

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

  // Added: Track last message time before app sleep
  DateTime? _lastMessageTimeBeforeSleep;

  // --- GETTERS ---

  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  WebSocketStatus get wsStatus => _wsStatus;
  bool get unjoinedChannelsExpanded => _unjoinedChannelsExpanded;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;

  List<Message> get currentChannelMessages => chatState.messagesForSelectedChannel;
  String get selectedConversationTarget => chatState.selectedConversationTarget;
  List<ChannelMember> get members => chatState.membersForSelectedChannel;
  Map<String, String> get userAvatars => chatState.userAvatars;
  List<String> get joinedPublicChannelNames => chatState.joinedPublicChannelNames;
  List<String> get unjoinedPublicChannelNames => chatState.unjoinedPublicChannelNames;
  List<String> get dmChannelNames => chatState.dmChannelNames;

  MainLayoutViewModel({required this.username, this.token}) {
    if (token == null) {
      print("[ViewModel] Error: Token is null. Cannot initialize.");
      _loadingChannels = false;
      _channelError = "Authentication token not found.";
      return;
    }

    chatState = ChatState();
    _chatController = ChatController(
      username: username,
      token: token!,
      chatState: chatState,
    );

    _initialize();
  }

  void _initialize() async {
    WidgetsBinding.instance.addObserver(this);

    chatState.addListener(_onChatStateChanged);

    _wsStatusSub = _chatController.wsStatusStream.listen(_onWsStatusChanged);
    _errorSub = _chatController.errorStream.listen(_onErrorChanged);

    await _chatController.initialize();

    // Load history for the initially selected channel
    if (selectedConversationTarget.startsWith('#')) {
      await _chatController.loadChannelHistory(selectedConversationTarget, limit: 100);
    }
  }

  void _onChatStateChanged() {
    _scrollToBottomIfScrolled();
    notifyListeners();
  }

  void _onWsStatusChanged(WebSocketStatus status) {
    if (status == WebSocketStatus.connected) {
      _loadingChannels = false;
      _channelError = null;
    } else {
      _loadingChannels = status == WebSocketStatus.connecting;
    }
    _wsStatus = status;
    notifyListeners();
  }

  void _onErrorChanged(String? error) {
    _channelError = error;
    _loadingChannels = false;
    notifyListeners();
  }

  // --- App Lifecycle Handling for Missed Messages ---

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // When app goes to background, save last message time and disconnect WebSocket
      _lastMessageTimeBeforeSleep = _getLastMessageTime();
      _chatController.disconnectWebSocket();
    } else if (state == AppLifecycleState.resumed) {
      // When app comes back to foreground, reconnect WebSocket and fetch missed messages
      _chatController.connectWebSocket();
      _fetchMissedMessages();
    }
  }

  DateTime? _getLastMessageTime() {
    final messages = currentChannelMessages;
    return messages.isNotEmpty ? messages.last.time : null;
  }

  Future<void> _fetchMissedMessages() async {
    if (_lastMessageTimeBeforeSleep == null) return;

    final currentTarget = selectedConversationTarget;
    if (!currentTarget.startsWith('#')) return; // Only fetch for channels

    try {
      // Fetch messages since we were last active (API returns List<Message>)
      final newMessages = await _chatController.apiService.fetchMessagesSince(
        currentTarget,
        _lastMessageTimeBeforeSleep!
      );

      // Add new messages to chat state (merge)
      chatState.addMessageBatch(currentTarget, newMessages);
    } catch (e) {
      print('Error fetching missed messages: $e');
    }
  }

  void toggleLeftDrawer() {
    _showLeftDrawer = !_showLeftDrawer;
    if (_showLeftDrawer) _showRightDrawer = false;
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    if (_showRightDrawer) _showLeftDrawer = false;
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

  void _scrollToBottomIfScrolled() {
    if (_scrollController.hasClients) {
      final isAtBottom = _scrollController.position.maxScrollExtent - _scrollController.offset < 200;
      if (isAtBottom) {
        _scrollToBottom();
      }
    }
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text;
    if (text.trim().isEmpty) return;
    _msgController.clear();
    await _chatController.handleSendMessage(text);
    _scrollToBottom();
  }

  void onChannelSelected(String channelName) {
    chatState.selectConversation(channelName);
    _scrollToBottom();
    if (channelName.startsWith('#')) {
      _chatController.loadChannelHistory(channelName, limit: 100); // Updated to 100
    }
  }

  void onUnjoinedChannelTap(String channelName) => _chatController.joinChannel(channelName);
  void onDmSelected(String dmChannelName) => onChannelSelected(dmChannelName);
  void partChannel(String channelName) => _chatController.partChannel(channelName);

  void selectMainView() {
    final index = chatState.channels.indexWhere((c) => c.name.startsWith('#'));
    if (index != -1) {
      onChannelSelected(chatState.channels[index].name);
    } else if (chatState.channels.isNotEmpty) {
      onChannelSelected(chatState.channels[0].name);
    }
  }

  Future<void> uploadAttachment(String filePath) async {
    await _chatController.uploadAttachment(filePath);
    _scrollToBottom();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatState.removeListener(_onChatStateChanged);
    _wsStatusSub?.cancel();
    _errorSub?.cancel();
    _chatController.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}