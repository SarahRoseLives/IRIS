import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    _token = args != null && args.containsKey('token') ? args['token'] : null;

    if (_token != null) {
      _fetchChannels();
    }
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
          if (selectedChannel >= channels.length) selectedChannel = 0;
        });
      } else {
        setState(() => _error = data['message'] ?? "Failed to load channels");
      }
    } catch (e) {
      setState(() => _error = "Network error: $e");
    }

    setState(() => _loadingChannels = false);
  }

  void _sendMessage() {
    if (_msgController.text.trim().isNotEmpty) {
      setState(() {
        messages.add('${widget.username}: ${_msgController.text}');
        _msgController.clear();
      });
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
                CircleAvatar(
                  radius: 28,
                  backgroundColor: const Color(0xFF5865F2),
                  child: const Text(
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
                          const Text("Channels",
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 22)),
                          IconButton(
                            icon: const Icon(Icons.refresh,
                                size: 18, color: Colors.white38),
                            tooltip: "Refresh",
                            onPressed: _fetchChannels,
                          )
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
                          channels.isNotEmpty
                              ? channels[selectedChannel.clamp(0, channels.length - 1)]
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
