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
  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> _channels = [];
  late ApiService _apiService; // Initialize later with token
  late WebSocketService _webSocketService;
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;

  // NEW: Map to store avatar URLs by username
  Map<String, String> _userAvatars = {};

  // --- NEW: Code block re-assembly state ---
  Map<String, List<String>> _codeBlockBuffers = {}; // Map channelName -> List of lines
  Map<String, String?> _codeBlockSenders = {}; // Map channelName -> current sender for the block
  Map<String, Timer?> _codeBlockTimers = {}; // Map channelName -> Timer for grouping
  final Duration _codeBlockTimeout = const Duration(milliseconds: 5000); // **Increased timeout to 5 seconds**

  // Regex to detect code block start/end lines
  final RegExp _codeBlockStartRegex = RegExp(r'^```(\w+)$'); // **Requires a language (e.g., ```dart)**
  final RegExp _codeBlockEndRegex = RegExp(r'^```$');        // Matches only ```
  // --- END NEW ---

  @override
  void initState() {
    super.initState();
    _webSocketService = WebSocketService();
    _webSocketService.statusStream.listen((status) {
      if (mounted) {
        setState(() {
          _wsStatus = status;
        });
        // Handle unauthorized status from WebSocket
        if (status == WebSocketStatus.unauthorized) {
          _handleLogout(); // Force logout
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

        if (_channels.isNotEmpty &&
            _selectedChannelIndex < _channels.length &&
            channelName == _channels[_selectedChannelIndex]) {
          _handleIncomingMessage(channelName, sender, content, messageTime);
          // NEW: Attempt to load avatar for the sender of the new message
          _loadAvatarForUser(sender);
        }
      }
    });
    _webSocketService.errorStream.listen((error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  // --- NEW: Message handling logic with re-assembly (added debug prints) ---
  void _handleIncomingMessage(String channelName, String sender, String content, String? messageTime) {
    print('\n--- _handleIncomingMessage ---');
    print('Channel: $channelName, Sender: $sender, Content: "$content"');

    setState(() {
      final String trimmedContent = content.trim(); // Trim for regex matching

      final bool isCodeStart = _codeBlockStartRegex.hasMatch(trimmedContent);
      final bool isCodeEnd = _codeBlockEndRegex.hasMatch(trimmedContent);

      print('isCodeStart: $isCodeStart, isCodeEnd: $isCodeEnd');

      // Check if a code block buffer is currently active for this channel AND from this sender
      final bool isBuffering = _codeBlockBuffers.containsKey(channelName) && _codeBlockSenders[channelName] == sender;
      print('isBuffering: $isBuffering (Current Sender: ${_codeBlockSenders[channelName]}, Incoming Sender: $sender)');


      if (isCodeStart && !isBuffering) {
        // Scenario 1: Start a new code block
        print('Scenario 1: Starting new code block.');
        _finalizeCodeBlock(channelName); // Finalize any previous incomplete block for this channel (e.g., due to timeout)
        _codeBlockBuffers[channelName] = [content]; // Store original content, not trimmed
        _codeBlockSenders[channelName] = sender;
        _startCodeBlockTimer(channelName, sender, messageTime);
      } else if (isBuffering) {
        // Scenario 2: Continue buffering for an active code block
        print('Scenario 2: Continuing code block.');
        _codeBlockBuffers[channelName]!.add(content); // Store original content, not trimmed
        _startCodeBlockTimer(channelName, sender, messageTime); // Reset timer

        if (isCodeEnd) {
          // Scenario 2a: End of code block detected, finalize and add to messages
          print('Scenario 2a: End of code block detected, finalizing.');
          _finalizeCodeBlock(channelName, sender: sender, time: messageTime);
        }
      } else {
        // Scenario 3: Regular message or a line that doesn't fit into an active code block
        print('Scenario 3: Regular message or mismatch. Finalizing any pending block and adding current message.');
        _finalizeCodeBlock(channelName); // Finalize any pending code block for this channel
        _addMessageToDisplay({
          'from': sender,
          'content': content,
          'time': messageTime,
        });
      }
    });
    _scrollToBottom();
    print('--- End _handleIncomingMessage ---\n');
  }

  void _startCodeBlockTimer(String channelName, String sender, String? time) {
    _codeBlockTimers[channelName]?.cancel();
    _codeBlockTimers[channelName] = Timer(_codeBlockTimeout, () {
      print('[_startCodeBlockTimer] Timeout for channel $channelName.');
      if (_codeBlockBuffers.containsKey(channelName) && _codeBlockSenders[channelName] == sender) {
        // Timeout occurred, finalize the buffered block even if ```end was not seen
        print('[_startCodeBlockTimer] Finalizing code block due to timeout.');
        _finalizeCodeBlock(channelName, sender: sender, time: time);
      }
    });
  }

  void _finalizeCodeBlock(String channelName, {String? sender, String? time}) {
    if (_codeBlockBuffers.containsKey(channelName) && _codeBlockBuffers[channelName]!.isNotEmpty) {
      final List<String> lines = _codeBlockBuffers[channelName]!;
      final String fullContent = lines.join('\n'); // Re-join lines with newlines
      print('[_finalizeCodeBlock] Finalizing content: "$fullContent"');

      _addMessageToDisplay({
        'from': sender ?? _codeBlockSenders[channelName] ?? 'Unknown',
        'content': fullContent,
        'time': time ?? DateTime.now().toIso8601String(), // Use time of first line, or current
      });

      // Clear the buffer and timer
      _codeBlockBuffers.remove(channelName);
      _codeBlockSenders.remove(channelName);
      _codeBlockTimers[channelName]?.cancel();
      _codeBlockTimers.remove(channelName);
    } else if (_codeBlockBuffers.containsKey(channelName) && _codeBlockBuffers[channelName]!.isEmpty) {
        // Buffer exists but is empty, just clear the state (e.g., if a start was detected but no lines followed)
        print('[_finalizeCodeBlock] Clearing empty code block state.');
        _codeBlockBuffers.remove(channelName);
        _codeBlockSenders.remove(channelName);
        _codeBlockTimers[channelName]?.cancel();
        _codeBlockTimers.remove(channelName);
    }
  }

  void _addMessageToDisplay(Map<String, dynamic> newMessage) {
    // Re-enabled a simple deduplication, as it's common practice.
    // This assumes that exact duplicates from the same sender within a short time are echoes.
    if (_messages.isNotEmpty &&
        _messages.last['from'] == newMessage['from'] &&
        _messages.last['content'] == newMessage['content']) {
      print('[_addMessageToDisplay] Detected exact duplicate from same sender, skipping.');
      return;
    }
    print('[_addMessageToDisplay] Adding message: ${newMessage['content']}');
    _messages.add(newMessage);
  }
  // --- END NEW: Message handling logic with re-assembly ---


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Retrieve the token passed from the login screen
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args?['token'] as String?;

    if (_token != null) {
      _apiService = ApiService(_token!); // Initialize ApiService with the token
      _fetchChannels(); // Fetch channels only after token is available
      if (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error) {
        _webSocketService.connect(_token!); // Connect WebSocket with the token
      }
      // NEW: Load current user's avatar on layout load
      _loadAvatarForUser(widget.username);
    } else {
      // If no token, force logout (should not happen if login flow is correct)
      _handleLogout();
    }
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    // Cancel all active timers to prevent memory leaks
    _codeBlockTimers.values.forEach((timer) => timer?.cancel());
    super.dispose();
  }

  // Handles logout by clearing token and navigating to login screen
  Future<void> _handleLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username'); // Clear username on logout as well
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  // NEW: Method to check and load avatar for a given user
  Future<void> _loadAvatarForUser(String username) async {
    // If avatar is already known, no need to recheck
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
        // Error checking specific URL, continue to next extension
        print("Error checking avatar for $username with extension $ext: $e");
      }
    }

    if (mounted) {
      setState(() {
        if (foundUrl != null) {
          _userAvatars[username] = foundUrl;
          print('Loaded avatar for $username: $foundUrl');
        } else {
          _userAvatars[username] = ''; // Mark as no avatar found to avoid repeated checks
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
          _selectedChannelIndex = 0; // Reset to 0 if current index is out of bounds
        }
      });
      if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
        _fetchChannelMessages(_channels[_selectedChannelIndex]);
      } else {
        // If no channels, clear messages
        setState(() {
          _messages.clear();
          _messages.add({'from': 'System', 'content': 'No channels available. Join one!', 'time': DateTime.now().toIso8601String()});
        });
      }
    } catch (e) {
      setState(() => _channelError = e.toString().replaceFirst('Exception: ', ''));
      print("Error fetching channels: $_channelError");
    } finally {
      setState(() => _loadingChannels = false);
    }
  }

  Future<void> _fetchChannelMessages(String channelName) async {
    setState(() {
      _messages = [{'from': 'System', 'content': 'Loading messages...', 'time': DateTime.now().toIso8601String()}];
    });
    try {
      final fetchedMessages = await _apiService.fetchChannelMessages(channelName);
      setState(() {
        _messages.clear(); // Clear the 'Loading messages...'
        // Process each fetched message through the re-assembly logic
        for (var msg in fetchedMessages) {
          final sender = msg['from'] ?? 'Unknown';
          _handleIncomingMessage(msg['channel_name'] ?? channelName, sender, msg['content'] ?? '', msg['time']);
          // NEW: Load avatar for all senders in historical messages
          _loadAvatarForUser(sender);
        }
      });
      _scrollToBottom();
    } catch (e) {
      print("Error fetching messages: $e");
      setState(() {
        _messages = [{'from': 'System', 'content': 'Failed to load messages for $channelName: ${e.toString().replaceFirst('Exception: ', '')}', 'time': DateTime.now().toIso8601String()}];
      });
    }
  }

  void _onChannelSelected(int index) {
    setState(() {
      _selectedChannelIndex = index;
      _showLeftDrawer = false; // Hide drawer after selecting a channel (common UX)
    });
    // Important: Finalize any pending code blocks when switching channels
    _codeBlockBuffers.keys.forEach((chan) => _finalizeCodeBlock(chan));
    _fetchChannelMessages(_channels[index]);
  }

  void _sendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _channels.isEmpty || _token == null) {
      return;
    }

    final currentChannel = _channels[_selectedChannelIndex];

    // Optimistic update: Add the message to the local list immediately.
    // We'll trust the WebSocket echo to confirm it, but this gives immediate feedback.
    // The local message sender does not need re-assembly because it sends the full block.
    setState(() {
      _addMessageToDisplay({
        'from': widget.username,
        'content': text,
        'time': DateTime.now().toIso8601String(), // Use current time for optimistic message
      });
      // NEW: Ensure current user's avatar is loaded if not already
      _loadAvatarForUser(widget.username);
    });
    _scrollToBottom(); // Scroll to bottom after adding message

    try {
      _webSocketService.sendMessage(currentChannel, text);
      _msgController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send message: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      // If send fails, consider removing the optimistic update or showing a failed status
      // For now, we'll let the WS stream handle discrepancies.
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
                  await _apiService.joinChannel(channelNameController.text);
                  _fetchChannels(); // Refresh channels after joining
                  if (mounted) Navigator.of(context).pop();
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
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      body: Row(
        children: [
          // The entire LeftDrawer now slides in and out as a single, combined unit
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
                              _showRightDrawer = false; // Ensure right drawer is closed if left opens
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
                        // New Profile Icon
                        if (_token != null) // Only show if authenticated
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
                              _showLeftDrawer = false; // Close left drawer if right opens
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
                      messages: _messages,
                      scrollController: _scrollController,
                      userAvatars: _userAvatars, // Pass the userAvatars map
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