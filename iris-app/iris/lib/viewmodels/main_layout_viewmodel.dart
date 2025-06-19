// lib/viewmodels/main_layout_viewmodel.dart
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:iris/services/notification_service.dart';
import 'package:get_it/get_it.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart';
import '../config.dart';
import '../models/channel.dart'; // Import Channel model
import '../models/channel_member.dart'; // Import ChannelMember model

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver {
  final String username;
  late ApiService _apiService;
  late WebSocketService _webSocketService;

  int _selectedChannelIndex = 0;
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  String? _token;

  final List<String> _dms = ['Alice', 'Bob', 'Eve'];
  final Map<String, List<Map<String, dynamic>>> _channelMessages = {};
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Channel> _channels = []; // MODIFIED: State now holds a list of Channel objects
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;
  final Map<String, String> _userAvatars = {};

  bool _isInitialHistoryLoad = true;
  Timer? _initialLoadTimer;
  bool _isAppFocused = true;

  int get selectedChannelIndex => _selectedChannelIndex;
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  String? get token => _token;
  List<String> get dms => _dms;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;
  WebSocketStatus get wsStatus => _wsStatus;
  Map<String, String> get userAvatars => _userAvatars;

  // MODIFIED: Getter for channel names from the list of Channel objects
  List<String> get channelNames => _channels.map((c) => c.name).toList();

  // MODIFIED: Getter for the members of the currently selected channel
  List<ChannelMember> get members {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].members;
    }
    return [];
  }

  // Getter for channel messages of the currently selected channel
  List<Map<String, dynamic>> get currentChannelMessages {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      final channelName = _channels[_selectedChannelIndex].name;
      return _channelMessages[channelName] ?? [];
    }
    return [];
  }

  MainLayoutViewModel({required this.username, String? initialToken}) {
    _token = initialToken;
    _apiService = ApiService(_token!);
    _webSocketService = WebSocketService();

    WidgetsBinding.instance.addObserver(this);

    _listenToWebSocketStatus();
    _listenToWebSocketChannels();
    _listenToWebSocketMessages();
    _listenToMembersUpdate(); // NEW: Listen for member updates
    _listenToWebSocketErrors();

    if (_token != null) {
      _fetchChannels();
      _connectWebSocket();
      _loadAvatarForUser(username);
      _initNotifications();
    } else {
      _handleLogout();
    }
  }

  // NEW: Listen for real-time member updates from the WebSocket
  void _listenToMembersUpdate() {
    _webSocketService.membersUpdateStream.listen((update) {
      final String channelName = update['channel_name'];
      final List<ChannelMember> newMembers = update['members'];

      try {
        // Find the channel in our state and update its members
        final channel = _channels.firstWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
        channel.members = newMembers;
        print("Updated members for $channelName. New count: ${newMembers.length}");
        notifyListeners(); // Update the UI
      } catch (e) {
        print("Received member update for an unknown channel: $channelName");
      }
    });
  }

  Future<void> _fetchChannels() async {
    _loadingChannels = true;
    _channelError = null;
    notifyListeners();

    try {
      // MODIFIED: The API service now returns List<Channel>
      _channels = await _apiService.fetchChannels();
      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }
      for (var channel in _channels) {
        _channelMessages.putIfAbsent(channel.name, () => []);
      }
      if (_channels.isNotEmpty) {
        final selectedChannelName = _channels[_selectedChannelIndex].name;
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

  void onChannelSelected(int index) {
    if (index >= _channels.length) return;
    _selectedChannelIndex = index;
    _showLeftDrawer = false;
    final selectedChannelName = _channels[index].name;

    if (_channelMessages[selectedChannelName] == null || _channelMessages[selectedChannelName]!.isEmpty) {
      _fetchChannelMessages(selectedChannelName);
    }
    _scrollToBottom();
    notifyListeners();
  }

  // --- Other methods remain the same ---
  // ... (paste the rest of your viewmodel code here, no other changes needed)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print("AppLifecycleState changed: $state");
    _isAppFocused = state == AppLifecycleState.resumed;
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
    _webSocketService.channelsStream.listen((channels) async {
       // When channels join/part, the simplest way to get new member lists
       // is to re-fetch everything from the API.
      await _fetchChannels();
    });
  }

    void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      print("[MainLayoutViewModel] Received message from WebSocketService stream: ${message['text']}");
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';

      if (!channelName.startsWith('#')) {
        channelName = '@$sender';
        if (channelNames.indexWhere((c) => c.toLowerCase() == channelName.toLowerCase()) == -1) {
            _channels.add(Channel(name: channelName, members: []));
            _channels.sort((a,b) => a.name.compareTo(b.name));
        }
      }

      final String content = message['text'] ?? '';
      final String? messageTime = message['time'];
      final int messageId = message['message_id'] ?? DateTime.now().millisecondsSinceEpoch;

      _addMessageToDisplay(channelName, {
        'from': sender,
        'content': content,
        'time': messageTime,
        'id': messageId,
      });
      _loadAvatarForUser(sender);

      String currentChannelName = _channels.isNotEmpty ? _channels[_selectedChannelIndex].name.toLowerCase() : '';
      final bool isCurrentChannel = channelName == currentChannelName;

      if (!_isInitialHistoryLoad) {
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
    _showRightDrawer = false;
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    _showLeftDrawer = false;
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
      return;
    }

    if (!_userAvatars.containsKey(username)) {
      _userAvatars[username] = '';
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
      _userAvatars[username] = '';
      print('No avatar found for $username, will use default initial.');
    }
    notifyListeners();
  }

  Future<void> _fetchChannelMessages(String channelName, {bool isInitialLoad = false}) async {
    if (channelName.isEmpty) return;
    if (channelName.startsWith('@')) return;

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
    final currentChannel = _channels[_selectedChannelIndex].name;
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

    final currentChannel = _channels[_selectedChannelIndex].name;
    String targetChannel = currentChannel.startsWith('@') ? currentChannel.substring(1) : currentChannel;

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

    if (normalizedChannelName.startsWith('@') && channelNames.indexWhere((c) => c.toLowerCase() == normalizedChannelName) == -1) {
      _channels.add(Channel(name: normalizedChannelName, members: []));
      _channels.sort((a,b) => a.name.compareTo(b.name));
    }

    final int targetIndex = channelNames.indexWhere((c) => c.toLowerCase() == normalizedChannelName);

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
    final flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'iris_channel_id',
      'IRIS Messages',
      channelDescription: 'Notifications for new IRIS chat messages.',
      importance: Importance.max,
      priority: Priority.high,
      showWhen: false,
    );
    const DarwinNotificationDetails darwinPlatformChannelSpecifics = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
      iOS: darwinPlatformChannelSpecifics,
    );
    final String payload = jsonEncode({
      'channel_name': channel,
      'sender': title,
      'type': channel.startsWith('@') ? 'private_message' : 'channel_message'
    });

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  void _addMessageToDisplay(String channelName, Map<String, dynamic> newMessage) {
    final normalizedChannel = channelName.toLowerCase();
    _channelMessages.putIfAbsent(normalizedChannel, () => []);
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
        ? _channels[_selectedChannelIndex].name
        : '';
    try {
      switch (command) {
        case 'join':
          if (args.isEmpty || !args.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /join <#channel_name>');
          } else {
             if (channelNames.any((c) => c.toLowerCase() == args.toLowerCase())) {
              _addInfoMessageToCurrentChannel('Already in channel: $args');
              _selectedChannelIndex = channelNames.indexWhere((c) => c.toLowerCase() == args.toLowerCase());
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
          } else if (!channelNames.any((c) => c.toLowerCase() == channelToPart.toLowerCase())) {
            _addInfoMessageToCurrentChannel('Not currently in channel: $channelToPart');
          } else {
            await _apiService.partChannel(channelToPart);
            _fetchChannels();
            if (currentChannelName.toLowerCase() == channelToPart.toLowerCase()) {
              _selectedChannelIndex = 0;
              if (_channels.isNotEmpty) {
                _fetchChannelMessages(_channels[_selectedChannelIndex].name);
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

          if (channelNames.indexWhere((c) => c.toLowerCase() == dmChannelName.toLowerCase()) == -1) {
            _channels.add(Channel(name: dmChannelName, members: []));
            _channels.sort((a,b) => a.name.compareTo(b.name));
          }
          _selectedChannelIndex = channelNames.indexWhere((c) => c.toLowerCase() == dmChannelName.toLowerCase());
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
 /join <#channel>     - Join a channel
 /part [#channel]      - Leave a channel
 /query <user> <msg>   - Send a private message
 /help               - Show this help message
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

  // NEW: _initNotifications was missing, adding it back.
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
    _initialLoadTimer?.cancel();
    super.dispose();
  }
}