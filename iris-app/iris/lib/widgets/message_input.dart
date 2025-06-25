import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class MessageInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;
  final VoidCallback onProfilePressed;
  final Future<void> Function(String) onAttachmentSelected;
  final List<String> allUsernames;

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
    required this.onProfilePressed,
    required this.onAttachmentSelected,
    required this.allUsernames,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _suggestionOverlay;
  List<String> _suggestions = [];
  int _selectedSuggestion = 0;

  @override
  void dispose() {
    _focusNode.dispose();
    _removeSuggestions();
    super.dispose();
  }

  void _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      await widget.onAttachmentSelected(pickedFile.path);
    }
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (selection.baseOffset < 0) {
      _removeSuggestions();
      return;
    }

    final cursor = selection.baseOffset;
    final triggerIndex = text.lastIndexOf('@', cursor - 1);
    if (triggerIndex == -1 ||
        (triggerIndex > 0 && !RegExp(r'[\s]').hasMatch(text[triggerIndex - 1]))) {
      _removeSuggestions();
      return;
    }

    final afterAt = text.substring(triggerIndex + 1, cursor);
    if (afterAt.isEmpty && _suggestions.isEmpty) {
      _removeSuggestions();
      return;
    }

    final matches = widget.allUsernames
        .where((u) => u.toLowerCase().startsWith(afterAt.toLowerCase()))
        .toList();

    if (matches.isEmpty) {
      _removeSuggestions();
      return;
    }
    _showSuggestions(matches, triggerIndex, afterAt);
  }

  void _showSuggestions(List<String> suggestions, int triggerIndex, String afterAt) {
    _removeSuggestions();
    _suggestions = suggestions;
    _selectedSuggestion = 0;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final Size size = renderBox.size;
    final overlay = Overlay.of(context);

    final textFieldBox = context.findRenderObject() as RenderBox;
    final textFieldOffset = textFieldBox.localToGlobal(Offset.zero);

    _suggestionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: textFieldOffset.dx + 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + size.height + 8,
        width: size.width - 32,
        child: Material(
          elevation: 6,
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF232428),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _suggestions.length,
              itemBuilder: (context, idx) {
                final username = _suggestions[idx];
                return ListTile(
                  dense: true,
                  tileColor: idx == _selectedSuggestion
                      ? Colors.blueGrey[700]
                      : Colors.transparent,
                  title: Text('@$username',
                      style: TextStyle(
                        color: idx == _selectedSuggestion
                            ? Colors.white
                            : Colors.white70,
                      )),
                  onTap: () {
                    _insertSuggestion(username);
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    overlay.insert(_suggestionOverlay!);
  }

  void _removeSuggestions() {
    _suggestionOverlay?.remove();
    _suggestionOverlay = null;
    _suggestions = [];
  }

  void _insertSuggestion(String username) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final cursor = selection.baseOffset;
    final triggerIndex = text.lastIndexOf('@', cursor - 1);

    if (triggerIndex == -1) return;
    final afterAt = text.substring(triggerIndex + 1, cursor);

    final newText =
        text.replaceRange(triggerIndex, cursor, '@$username ');
    final newCursor = triggerIndex + username.length + 2; // @ + username + space

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _removeSuggestions();
    FocusScope.of(context).requestFocus(_focusNode);
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
          IconButton(
            icon: const Icon(Icons.attach_file, color: Colors.white70),
            onPressed: _pickAndUploadImage,
            tooltip: "Attach Image",
          ),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: _focusNode,
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
              onChanged: (value) => _onTextChanged(),
              onEditingComplete: _removeSuggestions,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
            onPressed: () {
              widget.onSendMessage();
              _removeSuggestions();
            },
            tooltip: "Send",
          ),
        ],
      ),
    );
  }
}