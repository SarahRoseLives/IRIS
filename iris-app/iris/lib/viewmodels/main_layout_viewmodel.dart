// lib/viewmodels/main_layout_viewmodel.dart
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert'; // Import for jsonEncode
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'; // Import this
import 'package:collection/collection.dart'; // For more flexible list operations like findIndex

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart'; // Import AuthWrapper and the global flutterLocalNotificationsPlugin
import '../config.dart'; // Import config for apiHost and apiPort

class MainLayoutViewModel extends ChangeNotifier {
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

    _listenToWebSocketStatus();
    _listenToWebSocketChannels();
    _listenToWebSocketMessages();
    _listenToWebSocketErrors();

    if (_token != null) {
      _fetchChannels();
      _connectWebSocket();
      _loadAvatarForUser(username);
    } else {
      _handleLogout();
    }
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

      final String channelName = (message['channel_name'] ?? '').toLowerCase();

      final String sender = message['sender'] ?? 'Unknown';
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

      // Only show notification if it's not the current active channel and not during initial history load
      if (channelName != _channels[_selectedChannelIndex].toLowerCase() && !_isInitialHistoryLoad) {
        _showNotification(
          title: '$sender in $channelName',
          body: content,
          channel: channelName,
          messageId: messageId.toString(), // Pass message ID as string
        );
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
    _selectedChannelIndex = index;
    _showLeftDrawer = false; // Close drawer on selection
    _finalizeAllCodeBlocks();
    final selectedChannelName = _channels[index];
    // Always fetch messages when a channel is selected, unless it's already loading or has messages.
    // The previous condition `_channelMessages[selectedChannelName]!.isEmpty` was for *initial* load.
    // Here we ensure a fetch happens when a user clicks a channel.
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
      // --- CRUCIAL FIX: Explicitly fetch messages for the currently selected channel ---
      if (_channels.isNotEmpty) {
          final selectedChannelName = _channels[_selectedChannelIndex];
          print("[_fetchChannels] Calling _fetchChannelMessages for $selectedChannelName (after channels update)");
          await _fetchChannelMessages(selectedChannelName, isInitialLoad: true); // Mark as initial load
      }
      // --- END CRUCIAL FIX ---
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

    // Set the flag for initial history load
    if (isInitialLoad) {
      _isInitialHistoryLoad = true;
      _initialLoadTimer?.cancel(); // Cancel any previous timer
      _initialLoadTimer = Timer(const Duration(seconds: 2), () {
        _isInitialHistoryLoad = false;
        print("Initial history load flag reset.");
      });
    }

    // Show loading state initially
    _channelMessages[channelName] = [{'from': 'System', 'content': 'Loading messages...', 'time': DateTime.now().toIso8601String()}];
    notifyListeners();

    try {
      final fetchedMessages = await _apiService.fetchChannelMessages(channelName);
      _channelMessages[channelName]!.clear(); // Clear loading message
      for (var msg in fetchedMessages) {
        final sender = msg['from'] ?? 'Unknown';
        // Add fetched messages directly, they are already "finalized"
        _addMessageToDisplay(msg['channel_name'] ?? channelName, { // Use message's channel_name, which will be normalized by _addMessageToDisplay
          'from': sender,
          'content': msg['content'] ?? '',
          'time': msg['time'] ?? DateTime.now().toIso8601String(),
          'id': msg['id'] ?? DateTime.now().millisecondsSinceEpoch, // Ensure messages from history have an ID
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
      'id': DateTime.now().millisecondsSinceEpoch, // Give info messages an ID too
    });
    _scrollToBottom();
    notifyListeners();
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _token == null) {
      return;
    }

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
    // Add the message to local display immediately
    _addMessageToDisplay(currentChannel, {
      'from': username,
      'content': text,
      'time': DateTime.now().toIso8601String(),
      'id': DateTime.now().millisecondsSinceEpoch, // Assign an ID to sent messages
    });
    _loadAvatarForUser(username);
    _scrollToBottom();
    notifyListeners();

    try {
      _webSocketService.sendMessage(currentChannel, text);
    } catch (e) {
      _addInfoMessageToCurrentChannel('Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  // New method to handle notification tap and navigate
  void handleNotificationTap(String channelName, String messageId) {
    final normalizedChannelName = channelName.toLowerCase();
    print("Notification tapped: Navigating to channel $normalizedChannelName, message ID: $messageId");

    final int targetIndex = _channels.indexWhere((c) => c.toLowerCase() == normalizedChannelName);

    if (targetIndex != -1) {
      // If the channel is already loaded and selected, just scroll
      if (_selectedChannelIndex == targetIndex) {
        _scrollToMessage(messageId);
      } else {
        // Switch to the channel
        _selectedChannelIndex = targetIndex;
        _showLeftDrawer = false; // Close drawer if it was open
        notifyListeners(); // Notify to rebuild the UI with the new channel selected
        // After UI rebuilds, scroll to the message
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToMessage(messageId);
        });
      }
    } else {
      // If the channel is not in the current list, try to join it first
      _addInfoMessageToCurrentChannel('Attempting to join channel $channelName from notification.');
      _apiService.joinChannel(channelName).then((_) {
        _fetchChannels().then((_) {
          // After joining and fetching channels, try to select and scroll again
          final newTargetIndex = _channels.indexWhere((c) => c.toLowerCase() == normalizedChannelName);
          if (newTargetIndex != -1) {
            _selectedChannelIndex = newTargetIndex;
            notifyListeners();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _scrollToMessage(messageId);
            });
          } else {
            _addInfoMessageToCurrentChannel('Failed to join or find channel $channelName.');
          }
        });
      }).catchError((e) {
        _addInfoMessageToCurrentChannel('Failed to join channel $channelName: ${e.toString().replaceFirst('Exception: ', '')}');
      });
    }
  }

  void _scrollToMessage(String messageId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        print("Scroll controller has no clients to scroll to message.");
        return;
      }

      final currentChannelMessages = _channelMessages[_channels[_selectedChannelIndex]];
      if (currentChannelMessages == null || currentChannelMessages.isEmpty) {
        print("No messages in current channel to scroll to message ID: $messageId");
        return;
      }

      // Find the index of the message with the given ID
      final int messageIndex = currentChannelMessages.indexWhere((msg) => msg['id']?.toString() == messageId);

      if (messageIndex != -1) {
        // Calculate the offset to scroll to
        // Assuming each message item has a roughly consistent height
        // You might need to adjust this calculation based on your MessageList item layout
        const double estimatedMessageHeight = 70.0; // Estimate average message item height
        final double offset = messageIndex * estimatedMessageHeight;

        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOut,
        ).then((_) {
          print("Scrolled to message ID: $messageId at index $messageIndex");
          // Optionally, you can add a temporary highlight to the message here
        });
      } else {
        print("Message with ID $messageId not found in current channel.");
      }
    });
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

  // New method to show local notifications
  Future<void> _showNotification({
    required String title,
    required String body,
    required String channel,
    required String messageId,
  }) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      'iris_channel', // Channel ID
      'IRIS Messages', // Channel Name
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

    // Payload to pass channel and message ID when notification is tapped
    final String payload = jsonEncode({
      'channel': channel,
      'messageId': messageId,
    });

    await flutterLocalNotificationsPlugin.show(
      0, // Notification ID (can be unique per message if needed, or constant for chat)
      title,
      body,
      platformChannelSpecifics,
      payload: payload,
    );
  }

  // Code block helper functions (kept commented out for now)
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
        'id': DateTime.now().millisecondsSinceEpoch, // Add ID for code blocks too
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
    _channelMessages.putIfAbsent(channelName, () => []);
    _channelMessages[channelName]!.add(newMessage);
    _scrollToBottom();
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
          if (args.isEmpty) {
            _addInfoMessageToCurrentChannel('Usage: /join <channel_name>');
          } else {
            if (_channels.any((c) => c.toLowerCase() == args.toLowerCase())) {
              _addInfoMessageToCurrentChannel('Already in channel: $args');
              _selectedChannelIndex = _channels.indexWhere((c) => c.toLowerCase() == args.toLowerCase());
              _scrollToBottom();
            } else {
              await _apiService.joinChannel(args);
              _fetchChannels(); // This will trigger _fetchChannelMessages for the newly joined channel
            }
          }
          break;
        case 'part':
          String channelToPart = args.isNotEmpty ? args : currentChannelName;
          if (channelToPart.isEmpty) {
            _addInfoMessageToCurrentChannel('No channel specified to part from. Usage: /part <channel_name> or /part in a channel.');
          } else if (!_channels.any((c) => c.toLowerCase() == channelToPart.toLowerCase())) {
            _addInfoMessageToCurrentChannel('Not currently in channel: $channelToPart');
          } else {
            await _apiService.partChannel(channelToPart);
            _fetchChannels();
            if (currentChannelName.toLowerCase() == channelToPart.toLowerCase()) {
              _selectedChannelIndex = 0;
              if (_channels.isNotEmpty) {
                _fetchChannelMessages(_channels[_selectedChannelIndex]);
              } else {
                _addMessageToDisplay('#general', {'from': 'System', 'content': 'No channels available. Join one!', 'time': DateTime.now().toIso8601String(), 'id': DateTime.now().millisecondsSinceEpoch});
                _channels.add('#general');
                _selectedChannelIndex = _channels.indexOf('#general');
              }
            }
          }
          break;
        case 'nick':
          _addInfoMessageToCurrentChannel('The /nick command is not yet implemented in this client.');
          break;
        case 'me':
          if (args.isEmpty) {
            _addInfoMessageToCurrentChannel('Usage: /me <action_text>');
          } else {
            _webSocketService.sendMessage(currentChannelName, '/me $args');
            _addMessageToDisplay(currentChannelName, {
              'from': username,
              'content': '* $username $args',
              'time': DateTime.now().toIso8601String(),
              'id': DateTime.now().millisecondsSinceEpoch,
            });
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

          _webSocketService.sendMessage(dmChannelName, privateMessage);

          _channelMessages.putIfAbsent(dmChannelName, () => []);
          _addMessageToDisplay(dmChannelName, {
            'from': username,
            'content': privateMessage,
            'time': DateTime.now().toIso8601String(),
            'id': DateTime.now().millisecondsSinceEpoch,
          });
          if (!_channels.contains(dmChannelName)) {
            _channels.add(dmChannelName);
            _channels.sort();
          }
          _selectedChannelIndex = _channels.indexOf(dmChannelName);
          _scrollToBottom();
          break;
        case 'help':
          final helpMessage = """
Available IRC-like commands:
  /join <channel>         - Join a channel (e.g., /join #general)
  /part [channel]         - Leave the current channel or specified channel
  /me <action_text>       - Perform an action (e.g., /me is happy)
  /query <user> <msg>     - Send a private message to a user
  /help                   - Show this help message
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
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    _codeBlockTimers.values.forEach((timer) => timer?.cancel());
    _initialLoadTimer?.cancel();
    super.dispose();
  }
}