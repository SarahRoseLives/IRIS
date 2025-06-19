// lib/viewmodels/main_layout_viewmodel.dart

import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert'; // Import for jsonEncode
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Import this
import 'package:collection/collection.dart'; // For more flexible list operations like findIndex
import 'package:iris/services/notification_service.dart';
import 'package:get_it/get_it.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart'; // Import AuthWrapper and the service locator
import '../config.dart'; // Import config for apiHost and apiPort

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver { // Add WidgetsBindingObserver
  final String username;
  late ApiService _apiService;
  late WebSocketService _webSocketService;

  // State variables
  int _selectedChannelIndex = 0;
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  String? _token;

  final List<String> _dms = ['Alice', 'Bob', 'Eve']; // Example DMs
  final List<String> _members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory']; // Example Members
  final Map<String, List<Map<String, dynamic>>> _channelMessages = {};
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> _channels = [];
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;

  final Map<String, String> _userAvatars = {};

  // Flag to prevent notifications during initial history load
  bool _isInitialHistoryLoad = true;
  Timer? _initialLoadTimer; // To reset the flag after a short delay

  // New: Track app focus state
  bool _isAppFocused = true; // Assume focused initially

  // Code block handling state (kept commented out for now)
  final Map<String, List<String>> _codeBlockBuffers = {};
  final Map<String, String?> _codeBlockSenders = {};
  final Map<String, Timer?> _codeBlockTimers = {};
  final Duration _codeBlockTimeout = const Duration(milliseconds: 5000);

  final RegExp _codeBlockStartRegex = RegExp(r'^```(\w*)$');
  final RegExp _codeBlockEndRegex = RegExp(r'^```$');


  // Getters for UI to access state
  int get selectedChannelIndex => _selectedChannelIndex;
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  String? get token => _token;
  List<String> get dms => _dms;
  List<String> get members => _members;
  Map<String, List<Map<String, dynamic>>> get channelMessages => _channelMessages;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;
  List<String> get channels => _channels;
  WebSocketStatus get wsStatus => _wsStatus;
  Map<String, String> get userAvatars => _userAvatars;

  MainLayoutViewModel({required this.username, String? initialToken}) {
    _token = initialToken;
    _apiService = ApiService(_token!);
    _webSocketService = WebSocketService();

    // Add this ViewModel as a WidgetsBindingObserver
    WidgetsBinding.instance.addObserver(this);

    _listenToWebSocketStatus();
    _listenToWebSocketChannels();
    _listenToWebSocketMessages();
    _listenToWebSocketErrors();

    if (_token != null) {
      _fetchChannels();
      _connectWebSocket();
      _loadAvatarForUser(username);
      _initNotifications(); // <-- ADDED THIS CALL TO INITIALIZE NOTIFICATIONS
    } else {
      _handleLogout();
    }
  }

  // ** NEW METHOD TO INITIALIZE NOTIFICATIONS AND REGISTER TOKEN **
  Future<void> _initNotifications() async {
    // Use the GetIt service locator to get the singleton instance of NotificationService
    final notificationService = GetIt.instance<NotificationService>();
    final fcmToken = await notificationService.getFCMToken();

    if (fcmToken != null) {
      // Use the existing ApiService instance to register the token
      await _apiService.registerFCMToken(fcmToken);
    }
  }

  // Override didChangeAppLifecycleState from WidgetsBindingObserver
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print("AppLifecycleState changed: $state");
    _isAppFocused = state == AppLifecycleState.resumed;
    // You could optionally notifyListeners here if UI changes based on focus
    // but typically not needed for just notification logic.
  }

  void _listenToWebSocketStatus() {
    _webSocketService.statusStream.listen((status) {
      _wsStatus = status;
      notifyListeners();
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
    });
  }

  void _listenToWebSocketChannels() {
    _webSocketService.channelsStream.listen((channels) {
      _channels = channels;
      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }
      for (var channelName in _channels) {
        _channelMessages.putIfAbsent(channelName, () => []);
      }
      notifyListeners();
      // This listener handles channels being updated (e.g., via WebSocket initial state)
      // Ensure messages are fetched for the current channel after channel list updates
      if (_channels.isNotEmpty) { // Only attempt if channels are available
        _fetchChannelMessages(_channels[_selectedChannelIndex], isInitialLoad: true); // Mark as initial load
      }
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      print("[MainLayoutViewModel] Received message from WebSocketService stream: ${message['text']}");

      // Handle private messages by creating a channel name with the sender
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';

      // If the channel name doesn't start with '#', it's a PM.
      // The channel for a PM should be identified by the sender's name.
      if (!channelName.startsWith('#')) {
        channelName = '@$sender';
        // Ensure the PM channel exists in the UI list
        if (!_channels.contains(channelName)) {
            _channels.add(channelName);
            _channels.sort(); // Keep the list sorted
        }
      }

      final String content = message['text'] ?? '';
      final String? messageTime = message['time'];
      final int messageId = message['message_id'] ?? DateTime.now().millisecondsSinceEpoch; // Use a message ID if available, otherwise timestamp

      _addMessageToDisplay(channelName, {
        'from': sender,
        'content': content,
        'time': messageTime,
        'id': messageId, // Store the message ID
      });
      _loadAvatarForUser(sender);

      // Determine if a notification should be shown
      String currentChannelName = _channels.isNotEmpty ? _channels[_selectedChannelIndex].toLowerCase() : '';
      final bool isCurrentChannel = channelName == currentChannelName;
      final bool isMention = content.toLowerCase().contains(username.toLowerCase());

      if (!_isInitialHistoryLoad) {
        // Only show notifications if the app is not focused or the message is not for the current channel.
        if (!isCurrentChannel || !_isAppFocused) {
           _showNotification(
            title: sender,
            body: content,
            channel: channelName,
            messageId: messageId.toString(),
          );
        }
      }
      notifyListeners();
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      print("[MainLayoutViewModel] WebSocket Error: $error");
    });
  }

  void _connectWebSocket() {
    if (_token != null && (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error)) {
      _webSocketService.connect(_token!);
    }
  }

  void toggleLeftDrawer() {
    _showLeftDrawer = !_showLeftDrawer;
    _showRightDrawer = false; // Close right drawer if left opens
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    _showLeftDrawer = false; // Close left drawer if right opens
    notifyListeners();
  }

  void onChannelSelected(int index) {
    if (index >= _channels.length) return; // Bounds check
    _selectedChannelIndex = index;
    _showLeftDrawer = false; // Close drawer on selection
    _finalizeAllCodeBlocks();
    final selectedChannelName = _channels[index];
    if (_channelMessages[selectedChannelName] == null || _channelMessages[selectedChannelName]!.isEmpty ||
        (_channelMessages[selectedChannelName]!.length == 1 && _channelMessages[selectedChannelName]![0]['content'] == 'Loading messages...')) {
        _fetchChannelMessages(selectedChannelName);
    }
    _scrollToBottom();
    notifyListeners();
  }

  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    AuthWrapper.forceLogout();
  }

  Future<void> _loadAvatarForUser(String username) async {
    if (_userAvatars.containsKey(username) && _userAvatars[username] != null && _userAvatars[username]!.isNotEmpty) {
      return; // Already loaded or confirmed no avatar exists
    }

    if (!_userAvatars.containsKey(username)) {
      _userAvatars[username] = ''; // Indicates a check is in progress or failed
    }

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
        print("Error checking avatar for $username with extension $ext: $e");
      }
    }

    if (foundUrl != null) {
      _userAvatars[username] = foundUrl;
      print('Loaded avatar for $username: $foundUrl');
    } else {
      _userAvatars[username] = ''; // Confirmed no avatar found
      print('No avatar found for $username, will use default initial.');
    }
    notifyListeners();
  }

  Future<void> _fetchChannels() async {
    _loadingChannels = true;
    _channelError = null;
    notifyListeners();

    try {
      final fetchedChannels = await _apiService.fetchChannels();
      _channels = fetchedChannels;
      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }
      for (var channelName in _channels) {
        _channelMessages.putIfAbsent(channelName, () => []);
      }
      if (_channels.isNotEmpty) {
          final selectedChannelName = _channels[_selectedChannelIndex];
          print("[_fetchChannels] Calling _fetchChannelMessages for $selectedChannelName (after channels update)");
          await _fetchChannelMessages(selectedChannelName, isInitialLoad: true);
      }
    } catch (e) {
      _channelError = e.toString().replaceFirst('Exception: ', '');
      print("Error fetching channels: $_channelError");
    } finally {
      _loadingChannels = false;
      notifyListeners();
    }
  }

  Future<void> _fetchChannelMessages(String channelName, {bool isInitialLoad = false}) async {
    if (channelName.isEmpty) return;
    if (channelName.startsWith('@')) return; // Don't fetch history for PMs yet

    if (isInitialLoad) {
      _isInitialHistoryLoad = true;
      _initialLoadTimer?.cancel();
      _initialLoadTimer = Timer(const Duration(seconds: 2), () {
        _isInitialHistoryLoad = false;
        print("Initial history load flag reset.");
      });
    }

    _channelMessages[channelName] = [{'from': 'System', 'content': 'Loading messages...', 'time': DateTime.now().toIso8601String()}];
    notifyListeners();

    try {
      final fetchedMessages = await _apiService.fetchChannelMessages(channelName);
      _channelMessages[channelName]!.clear();
      for (var msg in fetchedMessages) {
        final sender = msg['from'] ?? 'Unknown';
        _addMessageToDisplay(channelName, {
          'from': sender,
          'content': msg['content'] ?? '',
          'time': msg['time'] ?? DateTime.now().toIso8601String(),
          'id': msg['id'] ?? DateTime.now().millisecondsSinceEpoch,
        });
        _loadAvatarForUser(sender);
      }
      _scrollToBottom();
    } catch (e) {
      print("Error fetching messages: $e");
      _channelMessages[channelName] = [{'from': 'System', 'content': 'Failed to load messages for $channelName: ${e.toString().replaceFirst('Exception: ', '')}', 'time': DateTime.now().toIso8601String()}];
    } finally {
      notifyListeners();
    }
  }

  void _addInfoMessageToCurrentChannel(String message) {
    if (_channels.isEmpty || _selectedChannelIndex >= _channels.length) {
      print("Cannot add info message: No channel selected.");
      return;
    }
    final currentChannel = _channels[_selectedChannelIndex];
    _addMessageToDisplay(currentChannel, {
      'from': 'IRIS Bot',
      'content': message,
      'time': DateTime.now().toIso8601String(),
      'id': DateTime.now().millisecondsSinceEpoch,
    });
    _scrollToBottom();
    notifyListeners();
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _token == null) return;
    _msgController.clear();

    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }

    if (_channels.isEmpty || _selectedChannelIndex >= _channels.length) {
      _addInfoMessageToCurrentChannel('Please join a channel before sending messages.');
      return;
    }

    final currentChannel = _channels[_selectedChannelIndex];

    // For PMs, the WebSocket expects the recipient's name as the channel
    String targetChannel = currentChannel.startsWith('@')
        ? currentChannel.substring(1)
        : currentChannel;

    _addMessageToDisplay(currentChannel, {
      'from': username,
      'content': text,
      'time': DateTime.now().toIso8601String(),
      'id': DateTime.now().millisecondsSinceEpoch,
    });
    _loadAvatarForUser(username);
    _scrollToBottom();
    notifyListeners();

    try {
      _webSocketService.sendMessage(targetChannel, text);
    } catch (e) {
      _addInfoMessageToCurrentChannel('Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void handleNotificationTap(String channelName, String messageId) {
    final normalizedChannelName = channelName.toLowerCase();
    print("Notification tapped: Navigating to channel $normalizedChannelName");

    // Ensure the PM channel exists if it doesn't already
    if (normalizedChannelName.startsWith('@') && !_channels.contains(normalizedChannelName)) {
      _channels.add(normalizedChannelName);
      _channels.sort();
    }

    final int targetIndex = _channels.indexWhere((c) => c.toLowerCase() == normalizedChannelName);

    if (targetIndex != -1) {
      _selectedChannelIndex = targetIndex;
      _showLeftDrawer = false;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
         _scrollToMessage(messageId);
      });
    }
  }

  void _scrollToMessage(String messageId) {
    // This is a basic implementation. A more robust solution might involve
    // item keys in the MessageList for precise scrolling. For now, we'll
    // just ensure the bottom is visible.
    _scrollToBottom();
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

  Future<void> _showNotification({
    required String title,
    required String body,
    required String channel,
    required String messageId,
  }) async {
    // Use the GetIt service locator to get the plugin instance
    final flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'iris_channel_id', // MUST MATCH the ID in AndroidManifest.xml
      'IRIS Messages',
      channelDescription: 'Notifications for new IRIS chat messages',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: false,
    );

    const DarwinNotificationDetails darwinPlatformChannelSpecifics =
        DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: darwinPlatformChannelSpecifics,
    );

    final String payload = jsonEncode({
      'channel_name': channel, // Use the key your background handler expects
      'sender': title,
      'type': channel.startsWith('@') ? 'private_message' : 'channel_message'
    });

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000), // Unique ID
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  void _startCodeBlockTimer(String channelName, String sender, String? time) {
    _codeBlockTimers[channelName]?.cancel();
    _codeBlockTimers[channelName] = Timer(_codeBlockTimeout, () {
      if (_codeBlockBuffers.containsKey(channelName) && _codeBlockSenders[channelName] == sender) {
        _finalizeCodeBlock(channelName, time: time);
        notifyListeners();
      }
    });
  }

  void _finalizeCodeBlock(String channelName, {String? sender, String? time}) {
    if (_codeBlockBuffers.containsKey(channelName) && _codeBlockBuffers[channelName]!.isNotEmpty) {
      final List<String> lines = _codeBlockBuffers[channelName]!;
      final String fullContent = lines.join('\n');

      _addMessageToDisplay(channelName, {
        'from': sender ?? _codeBlockSenders[channelName] ?? 'Unknown',
        'content': fullContent,
        'time': time ?? DateTime.now().toIso8601String(),
        'id': DateTime.now().millisecondsSinceEpoch,
      });

      _codeBlockBuffers.remove(channelName);
      _codeBlockSenders.remove(channelName);
      _codeBlockTimers[channelName]?.cancel();
      _codeBlockTimers.remove(channelName);
    } else {
      _codeBlockBuffers.remove(channelName);
      _codeBlockSenders.remove(channelName);
      _codeBlockTimers[channelName]?.cancel();
      _codeBlockTimers.remove(channelName);
    }
  }

  void _finalizeAllCodeBlocks() {
    for (var channelName in _codeBlockBuffers.keys.toList()) {
      _finalizeCodeBlock(channelName);
    }
  }

  void _addMessageToDisplay(String channelName, Map<String, dynamic> newMessage) {
    final normalizedChannel = channelName.toLowerCase();
    _channelMessages.putIfAbsent(normalizedChannel, () => []);

    // To prevent duplicates, check if a message with the same ID already exists
    if (_channelMessages[normalizedChannel]!.every((m) => m['id'] != newMessage['id'])) {
      _channelMessages[normalizedChannel]!.add(newMessage);
      _scrollToBottom();
    }
  }

  Future<void> _handleCommand(String commandText) async {
    final parts = commandText.substring(1).split(' ');
    final command = parts[0].toLowerCase();
    final args = parts.skip(1).join(' ').trim();

    String currentChannelName = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : '';

    try {
      switch (command) {
        case 'join':
          if (args.isEmpty || !args.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /join <#channel_name>');
          } else {
            if (_channels.any((c) => c.toLowerCase() == args.toLowerCase())) {
              _addInfoMessageToCurrentChannel('Already in channel: $args');
              _selectedChannelIndex = _channels.indexWhere((c) => c.toLowerCase() == args.toLowerCase());
              _scrollToBottom();
            } else {
              await _apiService.joinChannel(args);
              _fetchChannels();
            }
          }
          break;
        case 'part':
          String channelToPart = args.isNotEmpty ? args : currentChannelName;
          if (channelToPart.isEmpty) {
            _addInfoMessageToCurrentChannel('Usage: /part <#channel_name>');
          } else if (!_channels.any((c) => c.toLowerCase() == channelToPart.toLowerCase())) {
            _addInfoMessageToCurrentChannel('Not currently in channel: $channelToPart');
          } else {
            await _apiService.partChannel(channelToPart);
            _fetchChannels();
            if (currentChannelName.toLowerCase() == channelToPart.toLowerCase()) {
              _selectedChannelIndex = 0;
              if (_channels.isNotEmpty) {
                _fetchChannelMessages(_channels[_selectedChannelIndex]);
              }
            }
          }
          break;
        case 'query':
          if (args.isEmpty) {
            _addInfoMessageToCurrentChannel('Usage: /query <username> <message>');
            return;
          }
          final qParts = args.split(' ');
          if (qParts.length < 2) {
            _addInfoMessageToCurrentChannel('Usage: /query <username> <message>');
            return;
          }
          final targetUser = qParts[0];
          final privateMessage = qParts.skip(1).join(' ').trim();
          final dmChannelName = '@$targetUser';

          _webSocketService.sendMessage(targetUser, privateMessage);

          if (!_channels.contains(dmChannelName)) {
            _channels.add(dmChannelName);
            _channels.sort();
          }
          _selectedChannelIndex = _channels.indexOf(dmChannelName);
          _addMessageToDisplay(dmChannelName, {
            'from': username,
            'content': privateMessage,
            'time': DateTime.now().toIso8601String(),
            'id': DateTime.now().millisecondsSinceEpoch,
          });
          _scrollToBottom();
          break;
        case 'help':
          final helpMessage = """
Available IRC-like commands:
  /join <#channel>       - Join a channel
  /part [#channel]      - Leave a channel
  /query <user> <msg>   - Send a private message
  /help                 - Show this help message
""";
          _addInfoMessageToCurrentChannel(helpMessage);
          break;
        default:
          _addInfoMessageToCurrentChannel('Unknown command: /$command. Type /help for a list of commands.');
          break;
      }
    } catch (e) {
      _addInfoMessageToCurrentChannel('Failed to execute /$command: ${e.toString().replaceFirst('Exception: ', '')}');
      print('Command Error: $e');
    } finally {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    _codeBlockTimers.values.forEach((timer) => timer?.cancel());
    _initialLoadTimer?.cancel();
    super.dispose();
  }
}