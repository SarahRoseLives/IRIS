// lib/viewmodels/main_layout_viewmodel.dart
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:iris/services/notification_service.dart';
import 'package:get_it/get_it.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart';
import '../config.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver {
  final String username;
  late ApiService _apiService;
  late WebSocketService _webSocketService;

  int _selectedChannelIndex = 0;
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true; // Still true initially
  String? _channelError;
  String? _token;

  // MODIFIED: This map now stores Message objects instead of generic Maps.
  final Map<String, List<Message>> _channelMessages = {};

  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Channel> _channels = [];
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;
  final Map<String, String> _userAvatars = {};

  bool _isAppFocused = true;

  // --- GETTERS ---
  int get selectedChannelIndex => _selectedChannelIndex;
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  String? get token => _token;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;
  WebSocketStatus get wsStatus => _wsStatus;
  Map<String, String> get userAvatars => _userAvatars;

  List<String> get publicChannelNames =>
      _channels.where((c) => c.name.startsWith('#')).map((c) => c.name).toList();

  List<String> get dmChannelNames =>
      _channels.where((c) => c.name.startsWith('@')).map((c) => c.name).toList();

  String get selectedConversationTarget {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].name;
    }
    return _loadingChannels ? "Connecting..." : "No channels";
  }

  List<ChannelMember> get members {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].members;
    }
    return [];
  }

  // MODIFIED: This now returns the new Message objects.
  List<Message> get currentChannelMessages {
    final target = selectedConversationTarget.toLowerCase();
    return _channelMessages[target] ?? [];
  }

  // --- CONSTRUCTOR & INITIALIZATION ---
  MainLayoutViewModel({required this.username, String? initialToken}) {
    _token = initialToken;
    _apiService = ApiService(_token!);
    _webSocketService = WebSocketService();

    WidgetsBinding.instance.addObserver(this);

    _listenToWebSocketStatus();
    _listenToInitialState(); // NEW: Listen for the full initial state.
    _listenToWebSocketChannels(); // Still useful for join/part updates.
    _listenToWebSocketMessages();
    _listenToMembersUpdate();
    _listenToWebSocketErrors();

    if (_token != null) {
      // REMOVED: _fetchChannels() is no longer called here.
      _connectWebSocket();
      _loadAvatarForUser(username);
      _initNotifications();
    } else {
      _handleLogout();
    }
  }

  // --- WEBSOCKET LISTENERS ---

  /// NEW: Handles the 'initial_state' event which contains all channels, members, and message history.
  void _listenToInitialState() {
    _webSocketService.initialStateStream.listen((channelsPayload) {
      print("[ViewModel] Received initial state with ${channelsPayload.keys.length} channels.");
      _channels.clear();
      _channelMessages.clear();

      channelsPayload.forEach((channelName, channelData) {
        final channel = Channel.fromJson(channelData as Map<String, dynamic>);
        _channels.add(channel);

        // Populate messages for this channel
        final key = channel.name.toLowerCase();
        _channelMessages[key] = channel.messages;

        // Load avatars for all members in the channel
        for (var member in channel.members) {
          _loadAvatarForUser(member.nick);
        }
        // Load avatars for all message senders in the history
        for (var message in channel.messages) {
           _loadAvatarForUser(message.from);
        }
      });

      // Sort channels for consistent display
      _channels.sort((a, b) => a.name.compareTo(b.name));

      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }

      _loadingChannels = false;
      _channelError = null;
      notifyListeners();
      _scrollToBottom();
    });
  }

  void _listenToWebSocketStatus() {
    _webSocketService.statusStream.listen((status) {
      _wsStatus = status;
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
      notifyListeners();
    });
  }

  void _listenToWebSocketChannels() {
    _webSocketService.channelsStream.listen((channels) async {
       // This stream is now primarily for real-time join/part updates.
       // We can trigger a full refresh to keep it simple.
       await _fetchChannelsList();
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      print("[ViewModel] Received message: ${message['text']}");
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';
      final bool isPrivateMessage = !channelName.startsWith('#');

      String conversationTarget;
      if (isPrivateMessage) {
        final String conversationPartner = (sender.toLowerCase() == username.toLowerCase()) ? channelName : sender;
        conversationTarget = '@$conversationPartner';
        if (_channels.indexWhere((c) => c.name.toLowerCase() == conversationTarget.toLowerCase()) == -1) {
          _channels.add(Channel(name: conversationTarget, members: [], messages: []));
          _channels.sort((a, b) => a.name.compareTo(b.name));
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

      _addMessageToDisplay(conversationTarget.toLowerCase(), newMessage);
      _loadAvatarForUser(sender);
      notifyListeners();
    });
  }

 void _listenToMembersUpdate() {
    _webSocketService.membersUpdateStream.listen((update) {
      final String channelName = update['channel_name'];
      final List<ChannelMember> newMembers = update['members'];
      try {
        final channel = _channels.firstWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
        channel.members = newMembers;
        print("Updated members for $channelName. New count: ${newMembers.length}");
        notifyListeners();
      } catch (e) {
        print("Received member update for an unknown channel: $channelName");
      }
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      print("[ViewModel] WebSocket Error: $error");
    });
  }

  // --- DATA FETCHING & STATE MANAGEMENT ---

  /// Fetches only the list of channels, without messages. Used after join/part.
  Future<void> _fetchChannelsList() async {
    _loadingChannels = true;
    notifyListeners();
    try {
      final freshChannels = await _apiService.fetchChannels();
      // This is a naive update. A more sophisticated one would merge lists.
      _channels = freshChannels;
       if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }
      _channelError = null;
    } catch (e) {
      _channelError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _loadingChannels = false;
      notifyListeners();
    }
  }

  void _addMessageToDisplay(String channelNameKey, Message newMessage) {
    final key = channelNameKey.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    // Prevent duplicate messages from being added
    if (_channelMessages[key]!.every((m) => m.id != newMessage.id)) {
        _channelMessages[key]!.add(newMessage);
        _scrollToBottom();
    }
  }

  // --- USER ACTIONS ---

  void onChannelSelected(String channelName) => _selectConversation(channelName);
  void onDmSelected(String dmChannelName) => _selectConversation(dmChannelName);

  void _selectConversation(String conversationName) {
    final index = _channels.indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;
      _scrollToBottom();
      notifyListeners();
    }
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _token == null) return;
    _msgController.clear();

    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }

    final currentConversation = selectedConversationTarget;
    String target = currentConversation.startsWith('@') ? currentConversation.substring(1) : currentConversation;

    // Add message to UI immediately for responsiveness
    final sentMessage = Message(
        from: username,
        content: text,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString(), // Temporary ID
    );
    _addMessageToDisplay(currentConversation.toLowerCase(), sentMessage);
    notifyListeners();

    try {
      _webSocketService.sendMessage(target, text);
    } catch (e) {
        _addInfoMessageToCurrentChannel('Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  /// NEW (FIX): Add the missing method to handle notification taps.
  void handleNotificationTap(String channelName, String messageId) {
    print("[ViewModel] Notification tapped: Navigating to channel $channelName");

    // Ensure the channel exists if it's a DM, create it if not.
    if (channelName.startsWith('@') && _channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase()) == -1) {
      _channels.add(Channel(name: channelName, members: [], messages: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }

    final int targetIndex = _channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());

    if (targetIndex != -1) {
      _selectedChannelIndex = targetIndex;
      // Close drawers for a better user experience on tap.
      _showLeftDrawer = false;
      _showRightDrawer = false;
      notifyListeners();
      // After the UI updates, scroll to the bottom (or specific message if implemented).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  // --- HELPER & LIFECYCLE METHODS ---

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print("AppLifecycleState changed: $state");
    _isAppFocused = state == AppLifecycleState.resumed;
  }

  void _connectWebSocket() {
    if (_token != null && (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error)) {
      _webSocketService.connect(_token!);
    }
  }

  void toggleLeftDrawer() {
    _showLeftDrawer = !_showLeftDrawer;
    if(_showLeftDrawer) _showRightDrawer = false;
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    if(_showRightDrawer) _showLeftDrawer = false;
    notifyListeners();
  }

  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    AuthWrapper.forceLogout();
  }

  void selectMainView() {
    final index = _channels.indexWhere((c) => c.name.startsWith('#'));
    if (index != -1) {
      _selectedChannelIndex = index;
    } else if (_channels.isNotEmpty) {
      _selectedChannelIndex = 0;
    }
    notifyListeners();
  }

  Future<void> _loadAvatarForUser(String username) async {
    if (username.isEmpty || _userAvatars.containsKey(username)) return;

    _userAvatars[username] = ''; // Mark as checked

    final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
    String? foundUrl;

    for (final ext in possibleExtensions) {
      final String potentialAvatarUrl = 'http://$apiHost:$apiPort/avatars/$username$ext';
      try {
        final response = await http.head(Uri.parse(potentialAvatarUrl));
        if (response.statusCode == 200) {
          foundUrl = potentialAvatarUrl;
          break;
        }
      } catch (e) {
        // Suppress errors for non-existent avatars
      }
    }
    if (foundUrl != null) {
      _userAvatars[username] = foundUrl;
    }
    notifyListeners();
  }

  void _addInfoMessageToCurrentChannel(String message) {
    final currentChannel = selectedConversationTarget;
    final infoMessage = Message(
        from: 'IRIS Bot',
        content: message,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString());
    _addMessageToDisplay(currentChannel.toLowerCase(), infoMessage);
    notifyListeners();
  }

  Future<void> _handleCommand(String commandText) async {
    final parts = commandText.substring(1).split(' ');
    final command = parts[0].toLowerCase();
    final args = parts.skip(1).join(' ').trim();
    String currentChannelName = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex].name
        : '';
    try {
      switch (command) {
        case 'join':
          if (args.isEmpty || !args.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /join <#channel_name>');
          } else {
            await _apiService.joinChannel(args);
            await _fetchChannelsList();
            _selectConversation(args);
          }
          break;
        case 'part':
          String channelToPart = args.isNotEmpty ? args : currentChannelName;
          if (channelToPart.isEmpty || !channelToPart.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /part [#channel_name]');
          } else {
            await _apiService.partChannel(channelToPart);
            await _fetchChannelsList();
          }
          break;
        // ... Other commands
        default:
         _addInfoMessageToCurrentChannel('Unknown command: /$command. Type /help for a list of commands.');
      }
    } catch (e) {
       _addInfoMessageToCurrentChannel('Failed to execute /$command: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _initNotifications() async {
    final notificationService = GetIt.instance<NotificationService>();
    final fcmToken = await notificationService.getFCMToken();
    if (fcmToken != null) {
      await _apiService.registerFCMToken(fcmToken);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    super.dispose();
  }
}
