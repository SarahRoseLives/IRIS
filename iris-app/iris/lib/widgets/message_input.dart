import 'package:flutter/material.dart';

class MessageInput extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF232428),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
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
              // --- START MODIFICATIONS FOR MULTI-LINE INPUT ---
              maxLines: null, // Allows the TextField to expand vertically
              keyboardType: TextInputType.multiline, // Ensures the keyboard provides a newline button
              // The onSubmitted property is removed/commented out
              // so that pressing Enter creates a newline instead of sending the message.
              // Sending is now solely handled by the explicit IconButton.
              // onSubmitted: (_) => onSendMessage(), // REMOVE THIS LINE
              // --- END MODIFICATIONS FOR MULTI-LINE INPUT ---
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
            onPressed: onSendMessage, // This button will now be the primary way to send
            tooltip: "Send",
          ),
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