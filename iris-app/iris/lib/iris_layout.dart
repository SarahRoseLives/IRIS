import 'dart:async'; // Required for Timer
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
  String _wsStatus = 'Disconnected'; // To show WebSocket connection status

  final List<String> dms = ['Alice', 'Bob', 'Eve'];
  final List<String> members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory'];
  final List<String> messages = [
    'Welcome to #general!',
    'Alice: Hey there!',
    'Bob: Hello!',
    'SarahRose: This looks awesome!',
  ];
  final TextEditingController _msgController = TextEditingController();

  List<String> channels = [];
  WebSocketChannel? _ws;
  Timer? _reconnectTimer; // Timer for WebSocket reconnection attempts

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args != null && args.containsKey('token') ? args['token'] : null;

    if (_token != null) {
      _fetchChannels();
      // Only attempt to connect WebSocket if it's not already connected or connecting
      if (_ws == null || _wsStatus == 'Disconnected' || _wsStatus == 'Error') {
        _connectWebSocket(_token!);
      }
    }
  }

  @override
  void dispose() {
    _ws?.sink.close();
    _reconnectTimer?.cancel(); // Cancel any active reconnection timer
    _msgController.dispose();
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
          // If channels loaded successfully and it's the first load, set a welcome message
          if (messages.isEmpty && channels.isNotEmpty) {
            messages.add('Welcome to #${channels[selectedChannel]}!');
          }
        });
      } else {
        setState(() => _error = data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      setState(() => _error = "Network error: $e");
    } finally {
      setState(() => _loadingChannels = false);
    }
  }

  void _connectWebSocket(String token) {
    _reconnectTimer?.cancel(); // Clear any existing reconnect timer

    setState(() {
      _wsStatus = 'Connecting...';
    });
    print("[WebSocket] Attempting to connect...");

    // IMPORTANT: Ensure your backend serves WebSocket on this exact URL.
    // If running on a physical Android device, replace 'localhost' with '10.0.2.2'.
    // If running on a physical iOS device, replace 'localhost' with your machine's local IP.
    final uri = Uri.parse("ws://localhost:8080/ws/$token");

    try {
      _ws = WebSocketChannel.connect(uri);

      // Listen for the WebSocket connection to be ready
      _ws!.ready.then((_) {
        setState(() {
          _wsStatus = 'Connected';
        });
        print("[WebSocket] Connected successfully to: $uri");
      }).catchError((e) {
        print("[WebSocket] Initial connection error: $e");
        _handleWebSocketError(e);
      });

      // Listen for messages, errors, and connection closing
      _ws!.stream.listen((message) {
        final event = jsonDecode(message);
        print("[WebSocket] Received event: $event");

        if (event['type'] == 'initial_state') {
          final List<dynamic> receivedChannels = event['payload']['channels'] ?? [];
          setState(() {
            channels = receivedChannels.map((c) => c['name'].toString()).toList();
            // Ensure selectedChannel is still valid after initial state update
            if (selectedChannel >= channels.length) {
              selectedChannel = 0;
            }
            // Add a welcome message if the message list is empty
            if (messages.isEmpty && channels.isNotEmpty) {
              messages.add('Welcome to #${channels[selectedChannel]}!');
            } else if (messages.isEmpty && channels.isEmpty) {
              messages.add('No channels available.');
            }
          });
        }

        if (event['type'] == 'channel_join') {
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
              // Adjust selectedChannel if the removed channel was currently selected
              if (selectedChannel == indexToRemove) {
                if (channels.isNotEmpty) {
                  // If there are other channels, select the first one
                  selectedChannel = 0;
                  messages.clear();
                  messages.add('Welcome to #${channels[selectedChannel]}!');
                } else {
                  // No channels left
                  selectedChannel = 0; // Default or indicate no channel
                  messages.clear();
                  messages.add('No channels available.');
                }
              } else if (selectedChannel > indexToRemove) {
                // If a channel before the selected one was removed,
                // shift the selectedChannel index back by one
                selectedChannel--;
              }
            }
          });
        } else if (event['type'] == 'message') {
          final payload = event['payload'];
          final String sender = payload['sender'] ?? 'Unknown';
          final String text = payload['text'] ?? '';
          final String channelName = payload['channel_name'] ?? '';

          // Only add message if it belongs to the currently selected channel
          if (channels.isNotEmpty && selectedChannel < channels.length && channelName == channels[selectedChannel]) {
            setState(() {
              messages.add('$sender: $text');
            });
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
    _scheduleReconnect(); // Attempt to reconnect after a delay
  }

  void _handleWebSocketDone() {
    print("[WebSocket] Connection closed.");
    setState(() {
      _wsStatus = 'Disconnected';
    });
    _scheduleReconnect(); // Attempt to reconnect after a delay
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel(); // Cancel any existing timer
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
          'sender': widget.username,
        },
      });

      _ws?.sink.add(messageToSend);

      setState(() {
        messages.add('${widget.username}: $text');
        _msgController.clear();
      });
    } else if (_wsStatus != 'Connected') {
      print("[WebSocket] Cannot send message: WebSocket not connected (Status: $_wsStatus).");
      // Optionally show a user message in the UI, e.g., a SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot send message: WebSocket $_wsStatus.'),
          backgroundColor: Colors.red,
        ),
      );
    }
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
                          // Using Expanded to prevent overflow
                          const Expanded(
                            flex: 2, // Gives more space to "Channels"
                            child: Text(
                              "Channels",
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 22),
                            ),
                          ),
                          // Display WebSocket status, also expanded
                          Expanded(
                            flex: 1, // Gives less space, but allows flexing
                            child: Text(
                              _wsStatus,
                              textAlign: TextAlign.right,
                              overflow: TextOverflow.ellipsis, // Prevents overflow if text is very long
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
                                  messages.clear();
                                  messages.add('Welcome to #$channel!');
                                  // TODO: Implement fetching message history for the selected channel
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
                    padding: const EdgeInsets.all(16.0),
                    itemCount: messages.length,
                    itemBuilder: (context, idx) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6.0),
                        child: Text(
                          messages[idx],
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15),
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
