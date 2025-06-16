import 'package:flutter/material.dart';

import 'widgets/left_drawer.dart';
import 'widgets/right_drawer.dart';
import 'widgets/channel_panel.dart';
import 'widgets/message_list.dart';
import 'widgets/message_input.dart';
import 'services/api_service.dart';
import 'services/websocket_service.dart';
import 'config.dart';

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
  String? _token;

  final List<String> _dms = ['Alice', 'Bob', 'Eve'];
  final List<String> _members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory'];
  List<Map<String, dynamic>> _messages = [];
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> _channels = [];
  late ApiService _apiService;
  late WebSocketService _webSocketService;
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;

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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session expired. Please login again.'),
              backgroundColor: Colors.red,
            ),
          );
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
        if (_channels.isNotEmpty) {
          _fetchChannelMessages(_channels[_selectedChannelIndex]);
        }
      }
    });
    _webSocketService.messageStream.listen((message) {
      if (mounted) {
        final String channelName = message['channel_name'] ?? '';
        if (_channels.isNotEmpty &&
            _selectedChannelIndex < _channels.length &&
            channelName == _channels[_selectedChannelIndex]) {
          setState(() {
            final newMessage = {
              'from': message['sender'] ?? 'Unknown',
              'content': message['text'] ?? '',
              'time': message['time'],
            };

            // Simple de-duplication check: Avoid adding if the last message is identical
            // This assumes messages arrive in order and backend echoes correctly.
            if (_messages.isEmpty ||
                _messages.last['from'] != newMessage['from'] ||
                _messages.last['content'] != newMessage['content'] ||
                (_messages.last['time'] != null && newMessage['time'] != null && _messages.last['time'] != newMessage['time'])) {
              _messages.add(newMessage);
            }
          });
          _scrollToBottom();
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args != null && args.containsKey('token') ? args['token'] : null;

    if (_token != null) {
      _apiService = ApiService(_token!);
      _fetchChannels();
      if (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error) {
        _webSocketService.connect(_token!);
      }
    }
  }

  @override
  void dispose() {
    _msgController.dispose();
    _scrollController.dispose();
    _webSocketService.dispose();
    super.dispose();
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
      });
      if (_channels.isNotEmpty) {
        _fetchChannelMessages(_channels[_selectedChannelIndex]);
      }
    } catch (e) {
      setState(() => _channelError = e.toString().replaceFirst('Exception: ', ''));
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
        _messages = fetchedMessages;
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
    _fetchChannelMessages(_channels[index]);
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isNotEmpty && _channels.isNotEmpty) {
      final currentChannel = _channels[_selectedChannelIndex];
      _webSocketService.sendMessage(currentChannel, text);
      _msgController.clear();

      // OPTIMISTIC UPDATE: Add the message to the local list immediately
      setState(() {
        _messages.add({
          'from': widget.username,
          'content': text,
          'time': DateTime.now().toIso8601String(), // Use current time for optimistic message
        });
      });
      _scrollToBottom(); // Scroll to bottom after adding message
    } else if (_wsStatus != WebSocketStatus.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot send message: WebSocket $_wsStatus.'),
          backgroundColor: Colors.red,
        ),
      );
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
                              // Toggle the visibility of the LeftDrawer
                              _showLeftDrawer = !_showLeftDrawer;
                              // Ensure right drawer is closed if left opens
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
                      ],
                    ),
                  ),
                  Expanded(
                    child: MessageList(
                      messages: _messages,
                      scrollController: _scrollController,
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
