import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class IrisLayout extends StatefulWidget {
  final String username;
  const IrisLayout({super.key, required this.username});

  @override
  State<IrisLayout> createState() => _IrisLayoutState();
}

class _IrisLayoutState extends State<IrisLayout> {
  int selectedChannel = 0;
  bool showLeftDrawer = false;
  bool showRightDrawer = false;
  bool _loadingChannels = true;
  String? _error;
  String? _token;
  String _wsStatus = 'Disconnected';

  final List<String> dms = ['Alice', 'Bob', 'Eve'];
  final List<String> members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory'];
  List<Map<String, dynamic>> messages = [];
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<String> channels = [];
  WebSocketChannel? _ws;
  Timer? _reconnectTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args != null && args.containsKey('token') ? args['token'] : null;

    if (_token != null) {
      _fetchChannels();
      if (_ws == null || _wsStatus == 'Disconnected' || _wsStatus == 'Error') {
        _connectWebSocket(_token!);
      }
    }
  }

  @override
  void dispose() {
    _ws?.sink.close();
    _reconnectTimer?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchChannels() async {
    setState(() {
      _loadingChannels = true;
      _error = null;
    });

    final url = Uri.parse('http://localhost:8080/api/channels');
    try {
      final response = await http.get(url, headers: {
        'Authorization': 'Bearer $_token',
      });

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        final List<dynamic> apiChannels = data['channels'];
        setState(() {
          channels = apiChannels.map((c) => c['name'].toString()).toList();
          if (selectedChannel >= channels.length) {
            selectedChannel = 0;
          }
        });
        if (channels.isNotEmpty) {
          _fetchChannelMessages(channels[selectedChannel]);
        }
      } else {
        setState(() => _error = data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      setState(() => _error = "Network error: $e");
    } finally {
      setState(() => _loadingChannels = false);
    }
  }

  Future<void> _fetchChannelMessages(String channelName) async {
    if (_token == null || channelName.isEmpty) return;

    final url = Uri.parse('http://localhost:8080/api/channels/$channelName/messages');
    try {
      final response = await http.get(url, headers: {
        'Authorization': 'Bearer $_token',
      });

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['success'] == true) {
        setState(() {
          // Correctly handle 'messages' being null by providing an empty list
          final List<dynamic> receivedMessages = data['messages'] ?? [];
          messages = receivedMessages
              .map((msg) => {
                    'from': msg['from'],
                    'content': msg['content'],
                    'time': msg['time'],
                  })
              .toList();
        });
        _scrollToBottom();
      } else {
        print("Failed to load messages: ${data['message'] ?? response.statusCode}");
        setState(() {
          messages = [{'from': 'System', 'content': 'Failed to load messages for $channelName.', 'time': DateTime.now().toIso8601String()}];
        });
      }
    } catch (e) {
      print("Network error fetching messages: $e");
      setState(() {
        messages = [{'from': 'System', 'content': 'Network error fetching messages: $e', 'time': DateTime.now().toIso8601String()}];
      });
    }
  }

  void _connectWebSocket(String token) {
    _reconnectTimer?.cancel();

    setState(() {
      _wsStatus = 'Connecting...';
    });
    print("[WebSocket] Attempting to connect...");

    final uri = Uri.parse("ws://localhost:8080/ws/$token");

    try {
      _ws = WebSocketChannel.connect(uri);

      _ws!.ready.then((_) {
        setState(() {
          _wsStatus = 'Connected';
        });
        print("[WebSocket] Connected successfully to: $uri");
      }).catchError((e) {
        print("[WebSocket] Initial connection error: $e");
        _handleWebSocketError(e);
      });

      _ws!.stream.listen((message) {
        final event = jsonDecode(message);
        print("[WebSocket] Received event: $event");

        if (event['type'] == 'initial_state') {
          final List<dynamic> receivedChannels = event['payload']['channels'] ?? [];
          setState(() {
            channels = receivedChannels.map((c) => c['name'].toString()).toList();
            if (selectedChannel >= channels.length) {
              selectedChannel = 0;
            }
          });
          if (channels.isNotEmpty) {
            _fetchChannelMessages(channels[selectedChannel]);
          }
        } else if (event['type'] == 'channel_join') {
          final channel = event['payload']['name'];
          if (!channels.contains(channel)) {
            setState(() {
              channels.add(channel);
            });
          }
        } else if (event['type'] == 'channel_part') {
          final channelToRemove = event['payload']['name'];
          setState(() {
            final int indexToRemove = channels.indexOf(channelToRemove);
            if (indexToRemove != -1) {
              channels.removeAt(indexToRemove);
              if (selectedChannel == indexToRemove) {
                if (channels.isNotEmpty) {
                  selectedChannel = 0;
                  _fetchChannelMessages(channels[selectedChannel]);
                } else {
                  selectedChannel = 0;
                  messages = [{'from': 'System', 'content': 'No channels available.', 'time': DateTime.now().toIso8601String()}];
                }
              } else if (selectedChannel > indexToRemove) {
                selectedChannel--;
              }
            }
          });
        } else if (event['type'] == 'message') {
          final payload = event['payload'];
          final String channelName = payload['channel_name'] ?? '';
          if (channels.isNotEmpty &&
              selectedChannel < channels.length &&
              channelName == channels[selectedChannel]) {
            setState(() {
              messages.add({
                'from': payload['sender'] ?? 'Unknown',
                'content': payload['text'] ?? '',
                'time': DateTime.now().toIso8601String(),
              });
            });
            _scrollToBottom();
          }
        }
      }, onError: _handleWebSocketError, onDone: _handleWebSocketDone);
    } catch (e) {
      print("[WebSocket] Connection setup failed: $e");
      _handleWebSocketError(e);
    }
  }

  void _handleWebSocketError(dynamic error) {
    print("[WebSocket] Error occurred: $error");
    setState(() {
      _wsStatus = 'Error';
    });
    _scheduleReconnect();
  }

  void _handleWebSocketDone() {
    print("[WebSocket] Connection closed.");
    setState(() {
      _wsStatus = 'Disconnected';
    });
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_token != null && _wsStatus != 'Connecting...' && _wsStatus != 'Connected') {
        print("[WebSocket] Attempting to reconnect...");
        _connectWebSocket(_token!);
      }
    });
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isNotEmpty && channels.isNotEmpty && _wsStatus == 'Connected') {
      final currentChannel = channels[selectedChannel];
      final messageToSend = jsonEncode({
        'type': 'message',
        'payload': {
          'channel_name': currentChannel,
          'text': text,
        },
      });

      _ws?.sink.add(messageToSend);
      _msgController.clear();

      // Optimistically add the message to the local list for instant feedback
      setState(() {
        messages.add({
          'from': widget.username,
          'content': text,
          'time': DateTime.now().toIso8601String(),
        });
      });
      _scrollToBottom();

    } else if (_wsStatus != 'Connected') {
      print("[WebSocket] Cannot send message: WebSocket not connected (Status: $_wsStatus).");
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
          Container(
            width: 80,
            color: const Color(0xFF232428),
            child: Column(
              children: [
                const SizedBox(height: 20),
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF5865F2),
                  child: Text(
                    "IRIS",
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        letterSpacing: 1.5),
                  ),
                ),
                const SizedBox(height: 30),
                Expanded(
                  child: ListView(
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4.0),
                        child: Divider(color: Colors.white54),
                      ),
                      ...dms.map(
                        (dm) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: CircleAvatar(
                            backgroundColor: Colors.grey[800],
                            child: Text(dm[0],
                                style: const TextStyle(color: Colors.white)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showLeftDrawer)
            Container(
              width: 200,
              color: const Color(0xFF2B2D31),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            flex: 2,
                            child: Text(
                              "Channels",
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 22),
                            ),
                          ),
                          Expanded(
                            flex: 1,
                            child: Text(
                              _wsStatus,
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _wsStatus == 'Connected' ? Colors.greenAccent : Colors.redAccent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_loadingChannels)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: CircularProgressIndicator(),
                      )
                    else if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 13)),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          itemCount: channels.length,
                          itemBuilder: (context, idx) {
                            final channel = channels[idx];
                            return ListTile(
                              selected: selectedChannel == idx,
                              selectedTileColor: const Color(0xFF5865F2),
                              title: Text(channel,
                                  style: TextStyle(
                                    color: selectedChannel == idx
                                        ? Colors.white
                                        : Colors.white70,
                                  )),
                              onTap: () {
                                setState(() {
                                  selectedChannel = idx;
                                  showLeftDrawer = false;
                                  _fetchChannelMessages(channel);
                                });
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
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
                            showLeftDrawer = !showLeftDrawer;
                            showRightDrawer = false;
                          });
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          channels.isNotEmpty && selectedChannel < channels.length
                              ? channels[selectedChannel]
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
                            showRightDrawer = !showRightDrawer;
                            showLeftDrawer = false;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16.0),
                    itemCount: messages.length,
                    itemBuilder: (context, idx) {
                      final message = messages[idx];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              backgroundColor: Color(0xFF5865F2),
                              radius: 18,
                              child: Text(
                                message['from']?.toString().isNotEmpty == true
                                    ? message['from'][0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        message['from'] ?? 'Unknown',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 15),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        (message['time'] != null && message['time'] is String)
                                            ? DateTime.tryParse(message['time'])
                                                    ?.toLocal()
                                                    .toString()
                                                    .split('.')[0]
                                                    .substring(11, 16) ?? ''
                                            : '',
                                        style: const TextStyle(
                                            color: Colors.white54, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                  Text(
                                    message['content'] ?? '',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  color: const Color(0xFF232428),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12.0, vertical: 8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _msgController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: "Send a message...",
                            hintStyle:
                                const TextStyle(color: Colors.white54, fontSize: 15),
                            filled: true,
                            fillColor: const Color(0xFF383A40),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
                        onPressed: _sendMessage,
                        tooltip: "Send",
                      ),
                      IconButton(
                        icon: const Icon(Icons.attach_file,
                            color: Colors.white70),
                        onPressed: () {},
                        tooltip: "Attach",
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showRightDrawer)
            Container(
              width: 200,
              color: const Color(0xFF2B2D31),
              child: SafeArea(
                child: Column(
                  children: [
                    const ListTile(
                      title: Text(
                        "Members",
                        style: TextStyle(
                            color: Color(0xFF5865F2),
                            fontWeight: FontWeight.bold,
                            fontSize: 22),
                      ),
                    ),
                    ...members.map((m) => ListTile(
                          leading: CircleAvatar(child: Text(m[0])),
                          title: Text(m,
                              style: const TextStyle(color: Colors.white)),
                        )),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
