import 'package:flutter/material.dart';

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

  final List<String> channels = ['#general', '#random', '#support'];
  final List<String> dms = ['Alice', 'Bob', 'Eve'];
  final List<String> members = ['Alice', 'Bob', 'SarahRose', 'Eve', 'Mallory'];
  final List<String> messages = [
    'Welcome to #general!',
    'Alice: Hey there!',
    'Bob: Hello!',
    'SarahRose: This looks awesome!',
  ];
  final TextEditingController _msgController = TextEditingController();

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
          // Main bar - always visible
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
                // DMs
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
          // Custom left drawer
          if (showLeftDrawer)
            Container(
              width: 200,
              color: const Color(0xFF2B2D31),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "Channels",
                        style: TextStyle(
                            color: Colors.white60,
                            fontWeight: FontWeight.bold,
                            fontSize: 22),
                      ),
                    ),
                    ...channels.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final channel = entry.value;
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
                    }),
                  ],
                ),
              ),
            ),
          // Main content area
          Expanded(
            child: Column(
              children: [
                // Top bar: channel name + buttons
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
                          channels[selectedChannel],
                          style: const TextStyle(
                              color: Colors.white, fontSize: 20),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon:
                            const Icon(Icons.people, color: Colors.white70),
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
                // Message history
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
                // Message input bar
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
                                TextStyle(color: Colors.white54, fontSize: 15),
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
          // Custom right drawer
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
                          title:
                              Text(m, style: const TextStyle(color: Colors.white)),
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
