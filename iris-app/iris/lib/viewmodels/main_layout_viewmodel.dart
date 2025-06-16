// lib/viewmodels/main_layout_viewmodel.dart
import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart'; // Import AuthWrapper from main.dart
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

  // Code block handling state
  final Map<String, List<String>> _codeBlockBuffers = {};
  final Map<String, String?> _codeBlockSenders = {};
  final Map<String, Timer?> _codeBlockTimers = {};
  final Duration _codeBlockTimeout = const Duration(milliseconds: 5000);
  final RegExp _codeBlockStartRegex = RegExp(r'^```(\w+)$');
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
      if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
        _fetchChannelMessages(_channels[_selectedChannelIndex]);
      }
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      final String channelName = message['channel_name'] ?? '';
      final String sender = message['sender'] ?? 'Unknown';
      final String content = message['text'] ?? '';
      final String? messageTime = message['time'];

      _handleIncomingMessage(channelName, sender, content, messageTime);
      _loadAvatarForUser(sender);
      notifyListeners(); // Notify after message processing
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      // It's generally better for ViewModels to expose state that Widgets react to.
      // For critical errors like SnackBar, the Widget layer might still be the best place.
      // However, we can pass it as a special state to the UI.
      // For now, keeping the print for debugging.
      print("[MainLayoutViewModel] WebSocket Error: $error");
      // Could add a specific error state here if needed for UI feedback
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
    _finalizeAllCodeBlocks(); // Finalize any pending code blocks
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
    AuthWrapper.forceLogout(); // Use the static method to trigger logout
  }

  Future<void> _loadAvatarForUser(String username) async {
    if (_userAvatars.containsKey(username) && _userAvatars[username] != null && _userAvatars[username]!.isNotEmpty) {
      return; // Already loaded or confirmed no avatar exists
    }

    // Set a placeholder so we don't try to load again immediately
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
    notifyListeners(); // Notify listeners after updating avatar map
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
        if (_channelMessages[channelName]!.isEmpty) {
          _fetchChannelMessages(channelName);
        }
      }
    } catch (e) {
      _channelError = e.toString().replaceFirst('Exception: ', '');
      print("Error fetching channels: $_channelError");
    } finally {
      _loadingChannels = false;
      notifyListeners();
    }
  }

  Future<void> _fetchChannelMessages(String channelName) async {
    if (channelName.isEmpty) return;

    _channelMessages[channelName] = [{'from': 'System', 'content': 'Loading messages...', 'time': DateTime.now().toIso8601String()}];
    notifyListeners();

    try {
      final fetchedMessages = await _apiService.fetchChannelMessages(channelName);
      _channelMessages[channelName]!.clear(); // Clear loading message
      for (var msg in fetchedMessages) {
        final sender = msg['from'] ?? 'Unknown';
        _handleIncomingMessage(msg['channel_name'] ?? channelName, sender, msg['content'] ?? '', msg['time']);
        _loadAvatarForUser(sender); // Ensure avatars are loaded for fetched messages
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
    _addMessageToDisplay(currentChannel, {
      'from': username,
      'content': text,
      'time': DateTime.now().toIso8601String(),
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

  void _handleIncomingMessage(String channelName, String sender, String content, String? messageTime) {
    print('\n--- _handleIncomingMessage ---');
    print('Channel: $channelName, Sender: $sender, Content: "$content"');

    _channelMessages.putIfAbsent(channelName, () => []);

    final String trimmedContent = content.trim();

    final bool isCodeStart = _codeBlockStartRegex.hasMatch(trimmedContent);
    final bool isCodeEnd = _codeBlockEndRegex.hasMatch(trimmedContent);

    print('isCodeStart: $isCodeStart, isCodeEnd: $isCodeEnd');

    final bool isBuffering = _codeBlockBuffers.containsKey(channelName) && _codeBlockSenders[channelName] == sender;
    print('isBuffering: $isBuffering (Current Sender: ${_codeBlockSenders[channelName]}, Incoming Sender: $sender)');

    if (isCodeStart && !isBuffering) {
      print('Scenario 1: Starting new code block.');
      _finalizeCodeBlock(channelName);
      _codeBlockBuffers[channelName] = [content];
      _codeBlockSenders[channelName] = sender;
      _startCodeBlockTimer(channelName, sender, messageTime);
    } else if (isBuffering) {
      print('Scenario 2: Continuing code block.');
      _codeBlockBuffers[channelName]!.add(content);
      _startCodeBlockTimer(channelName, sender, messageTime);

      if (isCodeEnd) {
        print('Scenario 2a: End of code block detected, finalizing.');
        _finalizeCodeBlock(channelName, sender: sender, time: messageTime);
      }
    } else {
      print('Scenario 3: Regular message or mismatch. Finalizing any pending block and adding current message.');
      _finalizeCodeBlock(channelName);
      _addMessageToDisplay(channelName, {
        'from': sender,
        'content': content,
        'time': messageTime,
      });
    }
    print('--- End _handleIncomingMessage ---\n');
  }

  void _startCodeBlockTimer(String channelName, String sender, String? time) {
    _codeBlockTimers[channelName]?.cancel();
    _codeBlockTimers[channelName] = Timer(_codeBlockTimeout, () {
      print('[_startCodeBlockTimer] Timeout for channel $channelName.');
      if (_codeBlockBuffers.containsKey(channelName) && _codeBlockSenders[channelName] == sender) {
        print('[_startCodeBlockTimer] Finalizing code block due to timeout.');
        _finalizeCodeBlock(channelName, sender: sender, time: time);
        notifyListeners(); // Notify after timeout finalization
      }
    });
  }

  void _finalizeCodeBlock(String channelName, {String? sender, String? time}) {
    if (_codeBlockBuffers.containsKey(channelName) && _codeBlockBuffers[channelName]!.isNotEmpty) {
      final List<String> lines = _codeBlockBuffers[channelName]!;
      final String fullContent = lines.join('\n');
      print('[_finalizeCodeBlock] Finalizing content: "$fullContent"');

      _addMessageToDisplay(channelName, {
        'from': sender ?? _codeBlockSenders[channelName] ?? 'Unknown',
        'content': fullContent,
        'time': time ?? DateTime.now().toIso8601String(),
      });

      _codeBlockBuffers.remove(channelName);
      _codeBlockSenders.remove(channelName);
      _codeBlockTimers[channelName]?.cancel();
      _codeBlockTimers.remove(channelName);
    } else if (_codeBlockBuffers.containsKey(channelName) && _codeBlockBuffers[channelName]!.isEmpty) {
      print('[_finalizeCodeBlock] Clearing empty code block state.');
      _codeBlockBuffers.remove(channelName);
      _codeBlockSenders.remove(channelName);
      _codeBlockTimers[channelName]?.cancel();
      _codeBlockTimers.remove(channelName);
    }
  }

  void _finalizeAllCodeBlocks() {
    // Call this when changing channels to ensure no pending code blocks are lost
    for (var channelName in _codeBlockBuffers.keys.toList()) {
      _finalizeCodeBlock(channelName);
    }
  }

  void _addMessageToDisplay(String channelName, Map<String, dynamic> newMessage) {
    _channelMessages.putIfAbsent(channelName, () => []);
    final List<Map<String, dynamic>> messagesForChannel = _channelMessages[channelName]!;
    if (messagesForChannel.isNotEmpty &&
        messagesForChannel.last['from'] == newMessage['from'] &&
        messagesForChannel.last['content'] == newMessage['content'] &&
        newMessage['from'] != 'System' && newMessage['from'] != 'IRIS Bot') {
      print('[_addMessageToDisplay] Detected exact duplicate from same sender, skipping.');
      return;
    }
    print('[_addMessageToDisplay] Adding message to $channelName: ${newMessage['content']}');
    messagesForChannel.add(newMessage);
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
              _fetchChannels();
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
                _addMessageToDisplay('#general', {'from': 'System', 'content': 'No channels available. Join one!', 'time': DateTime.now().toIso8601String()});
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
  /join <channel>       - Join a channel (e.g., /join #general)
  /part [channel]       - Leave the current channel or specified channel
  /me <action_text>     - Perform an action (e.g., /me is happy)
  /query <user> <msg>   - Send a private message to a user
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
      notifyListeners(); // Notify after command handling to update UI
    }
  }

  void showJoinChannelDialog(BuildContext context) {
    final TextEditingController channelNameController = TextEditingController();
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Join Channel'),
          content: TextField(
            controller: channelNameController,
            decoration: const InputDecoration(hintText: 'Enter channel name (e.g., #general)'),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            ElevatedButton(
              child: const Text('Join'),
              onPressed: () async {
                if (channelNameController.text.isNotEmpty) {
                  Navigator.of(context).pop();
                  await _handleCommand('/join ${channelNameController.text}');
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    _codeBlockTimers.values.forEach((timer) => timer?.cancel());
    super.dispose();
  }
}