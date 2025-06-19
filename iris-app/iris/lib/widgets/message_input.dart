import 'package:flutter/material.dart';

class MessageInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;
  final VoidCallback onProfilePressed; // Callback for profile button

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
    required this.onProfilePressed,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  // The FocusNode and emoji picker state have been removed as they are no longer needed.

  @override
  Widget build(BuildContext context) {
    // The main widget is now just the Container, as the Column and EmojiPicker are gone.
    return Container(
      color: const Color(0xFF232428),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        children: [
          // Profile/Settings button
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white70),
            tooltip: "Profile",
            onPressed: widget.onProfilePressed, // Use the passed callback
          ),
          // The Emoji button has been removed.
          Expanded(
            child: TextField(
              controller: widget.controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Send a message...",
                hintStyle: const TextStyle(color: Colors.white54, fontSize: 15),
                filled: true,
                fillColor: const Color(0xFF383A40),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
              ),
              maxLines: null, // Allows the text field to grow vertically
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
          ),
          // Send button
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
            onPressed: widget.onSendMessage,
            tooltip: "Send",
          ),
          // Attachment button
          IconButton(
            icon: const Icon(Icons.attach_file, color: Colors.white70),
            onPressed: () {
              // TODO: Implement attachment functionality
            },
            tooltip: "Attach",
          ),
        ],
      ),
    );
  }
}
