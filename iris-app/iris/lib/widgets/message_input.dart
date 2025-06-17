import 'package:flutter/material.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart' as foundation;
import '../utils/irc_safe_emojis.dart'; // Import your curated list

class MessageInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;
  final VoidCallback onProfilePressed; // New callback for profile button

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
    required this.onProfilePressed, // Required for the new profile button
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  bool _showEmojiPicker = false;
  FocusNode _messageInputFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _messageInputFocusNode.addListener(() {
      if (_messageInputFocusNode.hasFocus && _showEmojiPicker && mounted) {
        setState(() {
          _showEmojiPicker = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _messageInputFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // This entire Container now includes both the profile and emoji/message input
        Container(
          color: const Color(0xFF232428),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            children: [
              // Profile/Settings button (moved here)
              IconButton(
                icon: const Icon(Icons.person, color: Colors.white70),
                tooltip: "Profile",
                onPressed: widget.onProfilePressed, // Use the passed callback
              ),
              // Emoji button
              IconButton(
                icon: Icon(
                  _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions,
                  color: Colors.white70,
                ),
                onPressed: () {
                  setState(() {
                    _showEmojiPicker = !_showEmojiPicker;
                    if (_showEmojiPicker) {
                      _messageInputFocusNode.unfocus();
                    } else {
                      _messageInputFocusNode.requestFocus();
                    }
                  });
                },
                tooltip: "Toggle Emoji Picker",
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _messageInputFocusNode,
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
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  onTap: () {
                    if (_showEmojiPicker) {
                      setState(() {
                        _showEmojiPicker = false;
                      });
                    }
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
                onPressed: widget.onSendMessage,
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
        ),
        Offstage(
          offstage: !_showEmojiPicker,
          child: SizedBox(
            height: 250,
            child: EmojiPicker(
              onEmojiSelected: (category, emoji) {
                final text = widget.controller.text;
                final selection = widget.controller.selection;
                final newText = text.replaceRange(selection.start, selection.end, emoji.emoji);
                widget.controller.value = widget.controller.value.copyWith(
                  text: newText,
                  selection: TextSelection.collapsed(offset: selection.start + emoji.emoji.length),
                );
              },
              config: Config(
                columns: 7,
                emojiSizeMax: 32 * (foundation.defaultTargetPlatform == TargetPlatform.iOS ? 1.20 : 1.0),
                verticalSpacing: 0,
                horizontalSpacing: 0,
                gridPadding: EdgeInsets.zero,
                // initCategory: Category.SMILEYS, // If using custom emojiSet, initCategory might be ignored or need a custom category ID
                bgColor: const Color(0xFF2B2D31),
                indicatorColor: const Color(0xFF5865F2),
                iconColor: Colors.white54,
                iconColorSelected: const Color(0xFF5865F2),
                backspaceColor: const Color(0xFF5865F2),
                skinToneDialogBgColor: const Color(0xFF383A40),
                skinToneIndicatorColor: Colors.grey,
                enableSkinTones: false,
                recentTabBehavior: RecentTabBehavior.NONE,
                noRecents: const Text(
                  'No Recents',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54, fontSize: 16),
                ),
                tabIndicatorAnimDuration: kTabScrollDuration,
                categoryIcons: const CategoryIcons(),
                buttonMode: ButtonMode.MATERIAL,
                checkPlatformCompatibility: true,
                // --- CORRECTED: Pass category and emojis as positional arguments to CategoryEmoji ---
                emojiSet: [
                  CategoryEmoji(
                    Category.ACTIVITIES, // Positional argument 1: Category
                    ircSafeEmojis.map((e) => Emoji(e, e, hasSkinTone: false)).toList(), // Positional argument 2: List<Emoji>
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}