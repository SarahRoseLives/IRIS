// main_layout.dart
import 'package:flutter/material.dart';
import 'dart:async'; // Import for Timer
import 'package:shared_preferences/shared_preferences.dart'; // Import for SharedPreferences
import 'package:http/http.dart' as http; // For checking avatar URL existence

import 'widgets/left_drawer.dart';
import 'widgets/right_drawer.dart';
import 'widgets/channel_panel.dart';
import 'widgets/message_list.dart';
import 'widgets/message_input.dart';
import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'screens/profile_screen.dart'; // Import the new ProfileScreen
import 'main.dart';
import 'config.dart'; // Import config for apiHost and apiPort

class IrisLayout extends StatefulWidget {
  final String username;
  const IrisLayout({super.key, required this.username});

  @override
  State<IrisLayout> createState() => _IrisLayoutState();
}

class _IrisLayoutState extends State<IrisLayout> {
  int _selectedChannelIndex = 0;
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  String? _token; // Store the authentication token

  final List<String> _dms = ['Alice', 'Bob', 'Eve'];
  final List<String> _members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory'];
  final Map<String, List<Map<String, dynamic>>> _channelMessages = {};
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> _channels = [];
  late ApiService _apiService; // Initialize later with token
  late WebSocketService _webSocketService;
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;

  Map<String, String> _userAvatars = {};

  Map<String, List<String>> _codeBlockBuffers = {};
  Map<String, String?> _codeBlockSenders = {};
  Map<String, Timer?> _codeBlockTimers = {};
  final Duration _codeBlockTimeout = const Duration(milliseconds: 5000);

  final RegExp _codeBlockStartRegex = RegExp(r'^```(\w+)$');
  final RegExp _codeBlockEndRegex = RegExp(r'^```$');

  @override
  void initState() {
    super.initState();
    _webSocketService = WebSocketService();
    _webSocketService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _wsStatus = status;
        });
        if (status == WebSocketStatus.unauthorized) {
          _handleLogout();
        }
      }
    });
    _webSocketService.channelsStream.listen((channels) {
      if (mounted) {
        setState(() {
          _channels = channels;
          if (_selectedChannelIndex >= _channels.length) {
            _selectedChannelIndex = 0;
          }
          for (var channelName in _channels) {
            _channelMessages.putIfAbsent(channelName, () => []);
          }
        });
        if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
          _fetchChannelMessages(_channels[_selectedChannelIndex]);
        }
      }
    });
    _webSocketService.messageStream.listen((message) {
      if (mounted) {
        final String channelName = message['channel_name'] ?? '';
        final String sender = message['sender'] ?? 'Unknown';
        final String content = message['text'] ?? '';
        final String? messageTime = message['time'];

        _handleIncomingMessage(channelName, sender, content, messageTime);
        _loadAvatarForUser(sender);
      }
    });
    _webSocketService.errorStream.listen((error) {
      if (mounted) {
        // Keep WebSocket errors in SnackBar, as they are truly critical system-level issues
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  void _handleIncomingMessage(String channelName, String sender, String content, String? messageTime) {
    print('\n--- _handleIncomingMessage ---');
    print('Channel: $channelName, Sender: $sender, Content: "$content"');

    setState(() {
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
    });
    if (_channels.isNotEmpty &&
        _selectedChannelIndex < _channels.length &&
        channelName == _channels[_selectedChannelIndex]) {
      _scrollToBottom();
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

  void _addMessageToDisplay(String channelName, Map<String, dynamic> newMessage) {
    // Only add if we have a valid channelName in our internal map
    if (!_channelMessages.containsKey(channelName)) {
      _channelMessages[channelName] = []; // Initialize if it somehow wasn't added yet
    }
    final List<Map<String, dynamic>> messagesForChannel = _channelMessages[channelName]!;
    if (messagesForChannel.isNotEmpty &&
        messagesForChannel.last['from'] == newMessage['from'] &&
        messagesForChannel.last['content'] == newMessage['content'] &&
        newMessage['from'] != 'System') { // Don't deduplicate system messages
      print('[_addMessageToDisplay] Detected exact duplicate from same sender, skipping.');
      return;
    }
    print('[_addMessageToDisplay] Adding message to $channelName: ${newMessage['content']}');
    messagesForChannel.add(newMessage);
  }

  // Removed _addSystemMessage as per new requirements for no command feedback in chat.
  // This helper will only be used by /help if needed, or by other non-command related system messages.
  void _addInfoMessageToCurrentChannel(String message) {
    if (_channels.isEmpty || _selectedChannelIndex >= _channels.length) {
      print("Cannot add info message: No channel selected.");
      return;
    }
    final currentChannel = _channels[_selectedChannelIndex];
    setState(() {
      _addMessageToDisplay(currentChannel, {
        'from': 'IRIS Bot', // Or 'System'
        'content': message,
        'time': DateTime.now().toIso8601String(),
      });
    });
    _scrollToBottom();
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args?['token'] as String?;

    if (_token != null) {
      _apiService = ApiService(_token!);
      _fetchChannels();
      if (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error) {
        _webSocketService.connect(_token!);
      }
      _loadAvatarForUser(widget.username);
    } else {
      _handleLogout();
    }
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    _codeBlockTimers.values.forEach((timer) => timer?.cancel());
    super.dispose();
  }

  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  Future<void> _loadAvatarForUser(String username) async {
    if (_userAvatars.containsKey(username) && _userAvatars[username] != null) {
      return;
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

    if (mounted) {
      setState(() {
        if (foundUrl != null) {
          _userAvatars[username] = foundUrl;
          print('Loaded avatar for $username: $foundUrl');
        } else {
          _userAvatars[username] = '';
          print('No avatar found for $username, will use default initial.');
        }
      });
    }
  }

  Future<void> _fetchChannels() async {
    setState(() {
      _loadingChannels = true;
      _channelError = null;
    });

    try {
      final fetchedChannels = await _apiService.fetchChannels();
      setState(() {
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
      });
      if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
        if (_channelMessages[_channels[_selectedChannelIndex]]!.isEmpty) {
          _fetchChannelMessages(_channels[_selectedChannelIndex]);
        }
      } else {
        setState(() {
          _channelMessages.clear();
          // Add a default message if no channels are available
          _addMessageToDisplay('#general', {'from': 'System', 'content': 'No channels available. Join one!', 'time': DateTime.now().toIso8601String()});
          // Ensure #general is in the channels list so it can be selected
          _channels.add('#general');
          _selectedChannelIndex = _channels.indexOf('#general');
        });
      }
    } catch (e) {
      setState(() => _channelError = e.toString().replaceFirst('Exception: ', ''));
      print("Error fetching channels: $_channelError");
      // Keep critical errors as SnackBar, but not command feedback
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error fetching channels: $_channelError"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() => _loadingChannels = false);
    }
  }

  Future<void> _fetchChannelMessages(String channelName) async {
    if (channelName.isEmpty) return;

    setState(() {
      _channelMessages[channelName] = [{'from': 'System', 'content': 'Loading messages...', 'time': DateTime.now().toIso8601String()}];
    });

    try {
      final fetchedMessages = await _apiService.fetchChannelMessages(channelName);
      setState(() {
        _channelMessages[channelName]!.clear();
        for (var msg in fetchedMessages) {
          final sender = msg['from'] ?? 'Unknown';
          _handleIncomingMessage(msg['channel_name'] ?? channelName, sender, msg['content'] ?? '', msg['time']);
          _loadAvatarForUser(sender);
        }
      });
      _scrollToBottom();
    } catch (e) {
      print("Error fetching messages: $e");
      setState(() {
        _channelMessages[channelName] = [{'from': 'System', 'content': 'Failed to load messages for $channelName: ${e.toString().replaceFirst('Exception: ', '')}', 'time': DateTime.now().toIso8601String()}];
      });
    }
  }

  void _onChannelSelected(int index) {
    setState(() {
      _selectedChannelIndex = index;
      _showLeftDrawer = false;
    });
    _codeBlockBuffers.keys.forEach((chan) => _finalizeCodeBlock(chan));

    final selectedChannelName = _channels[index];
    if (_channelMessages[selectedChannelName] == null || _channelMessages[selectedChannelName]!.isEmpty ||
        (_channelMessages[selectedChannelName]!.length == 1 && _channelMessages[selectedChannelName]![0]['content'] == 'Loading messages...')) {
      _fetchChannelMessages(selectedChannelName);
    }
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
              setState(() {
                _selectedChannelIndex = _channels.indexWhere((c) => c.toLowerCase() == args.toLowerCase());
              });
              _scrollToBottom();
            } else {
              await _apiService.joinChannel(args);
              // No direct feedback needed here, channelsStream will update
              _fetchChannels(); // Refresh channels list to include the new channel
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
            // No direct feedback needed here, channelsStream will update
            _fetchChannels(); // Refresh channels list to remove the parted channel
            if (currentChannelName.toLowerCase() == channelToPart.toLowerCase()) {
              setState(() {
                _selectedChannelIndex = 0;
              });
              if (_channels.isNotEmpty) {
                 _fetchChannelMessages(_channels[_selectedChannelIndex]);
              } else {
                 // If no channels left after parting, show a generic message
                 _addMessageToDisplay('#general', {'from': 'System', 'content': 'No channels available. Join one!', 'time': DateTime.now().toIso8601String()});
                 _channels.add('#general'); // Add it back as a selectable "empty" channel
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
            setState(() {
              _addMessageToDisplay(currentChannelName, {
                'from': widget.username,
                'content': '* ${widget.username} $args', // IRC convention for /me
                'time': DateTime.now().toIso8601String(),
              });
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

          _webSocketService.sendMessage(dmChannelName, privateMessage); // Send via WS

          setState(() {
            _channelMessages.putIfAbsent(dmChannelName, () => []);
            _addMessageToDisplay(dmChannelName, {
              'from': widget.username,
              'content': privateMessage,
              'time': DateTime.now().toIso8601String(),
            });
            if (!_channels.contains(dmChannelName)) {
              _channels.add(dmChannelName);
              _channels.sort();
            }
            _selectedChannelIndex = _channels.indexOf(dmChannelName);
          });
          _scrollToBottom();
          break;
        case 'help':
          final helpMessage = """
Available IRC-like commands:
  /join <channel>      - Join a channel (e.g., /join #general)
  /part [channel]      - Leave the current channel or specified channel
  /me <action_text>    - Perform an action (e.g., /me is happy)
  /query <user> <msg>  - Send a private message to a user
  /help                - Show this help message
""";
          _addInfoMessageToCurrentChannel(helpMessage); // Display help in current channel
          break;
        default:
          _addInfoMessageToCurrentChannel('Unknown command: /$command. Type /help for a list of commands.');
          break;
      }
    } catch (e) {
      // General error for command execution (e.g., API call failed)
      _addInfoMessageToCurrentChannel('Failed to execute /$command: ${e.toString().replaceFirst('Exception: ', '')}');
      print('Command Error: $e'); // Log for debugging
    }
  }

  void _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _token == null) {
      return;
    }

    _msgController.clear();

    if (text.startsWith('/')) {
      await _handleCommand(text); // Handle as a command
      return;
    }

    if (_channels.isEmpty || _selectedChannelIndex >= _channels.length) {
      // Only show this message if there's no actual channel selected to send to.
      // This is a client-side message, not a command.
      _addInfoMessageToCurrentChannel('Please join a channel before sending messages.');
      return;
    }

    final currentChannel = _channels[_selectedChannelIndex];

    setState(() {
      _addMessageToDisplay(currentChannel, {
        'from': widget.username,
        'content': text,
        'time': DateTime.now().toIso8601String(),
      });
      _loadAvatarForUser(widget.username);
    });
    _scrollToBottom();

    try {
      _webSocketService.sendMessage(currentChannel, text);
    } catch (e) {
      // Keep this as a Snackbar as it's a transient network issue for a regular message send
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}'),
            backgroundColor: Colors.red,
          ),
        );
      }
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

  void _showJoinChannelDialog() {
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
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> currentChannelMessages =
        _channels.isNotEmpty && _selectedChannelIndex < _channels.length
            ? _channelMessages[_channels[_selectedChannelIndex]] ?? []
            : [];

    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      body: Row(
        children: [
          LeftDrawer(
            dms: _dms,
            channels: _channels,
            selectedChannelIndex: _selectedChannelIndex,
            onChannelSelected: _onChannelSelected,
            loadingChannels: _loadingChannels,
            error: _channelError,
            wsStatus: _wsStatus,
            showDrawer: _showLeftDrawer,
          ),
          Expanded(
            child: SafeArea(
              child: Column(
                children: [
                  Container(
                    color: const Color(0xFF232428),
                    height: 56,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.menu, color: Colors.white54),
                          tooltip: "Open Channels Drawer",
                          onPressed: () {
                            setState(() {
                              _showLeftDrawer = !_showLeftDrawer;
                              _showRightDrawer = false;
                            });
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            _channels.isNotEmpty && _selectedChannelIndex < _channels.length
                                ? _channels[_selectedChannelIndex]
                                : "#loading",
                            style: const TextStyle(
                                color: Colors.white, fontSize: 20),
                          ),
                        ),
                        const Spacer(),
                        if (_token != null)
                          IconButton(
                            icon: const Icon(Icons.person, color: Colors.white70),
                            tooltip: "Profile",
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ProfileScreen(authToken: _token!),
                                ),
                              );
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.people, color: Colors.white70),
                          tooltip: "Open Members Drawer",
                          onPressed: () {
                            setState(() {
                              _showRightDrawer = !_showRightDrawer;
                              _showLeftDrawer = false;
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.logout, color: Colors.white70),
                          tooltip: "Logout",
                          onPressed: _handleLogout,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: MessageList(
                      messages: currentChannelMessages,
                      scrollController: _scrollController,
                      userAvatars: _userAvatars,
                    ),
                  ),
                  MessageInput(
                    controller: _msgController,
                    onSendMessage: _sendMessage,
                  ),
                ],
              ),
            ),
          ),
          if (_showRightDrawer)
            RightDrawer(members: _members),
        ],
      ),
    );
  }
}