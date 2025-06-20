import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class MessageInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;
  final VoidCallback onProfilePressed;
  final Function(String) onAttachmentSelected; // New callback for attachments

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
    required this.onProfilePressed,
    required this.onAttachmentSelected, // Add to constructor
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  Future<void> _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      widget.onAttachmentSelected(pickedFile.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF232428),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.person, color: Colors.white70),
            tooltip: "Profile",
            onPressed: widget.onProfilePressed,
          ),
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
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
            onPressed: widget.onSendMessage,
            tooltip: "Send",
          ),
          IconButton(
            icon: const Icon(Icons.attach_file, color: Colors.white70),
            onPressed: _pickAndUploadImage, // Updated to use our new method
            tooltip: "Attach Image",
          ),
        ],
      ),
    );
  }
}