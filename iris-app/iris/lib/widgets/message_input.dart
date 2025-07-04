import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../commands/slash_command.dart';
import '../utils/irc_safe_emojis.dart';

class MessageInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSendMessage;
  final VoidCallback onProfilePressed;
  final Future<String?> Function(String) onAttachmentSelected;
  final List<String> allUsernames;
  final List<SlashCommand> availableCommands; // <-- ADDED: For / commands

  const MessageInput({
    super.key,
    required this.controller,
    required this.onSendMessage,
    required this.onProfilePressed,
    required this.onAttachmentSelected,
    required this.allUsernames,
    required this.availableCommands, // <-- ADDED: To constructor
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final FocusNode _focusNode = FocusNode();
  OverlayEntry? _suggestionOverlay;

  // START OF CHANGE: Generic suggestion handling
  List<dynamic> _suggestions = [];
  String _suggestionType = ''; // Can be 'user' or 'command'
  int _selectedSuggestion = 0;
  // END OF CHANGE

  @override
  void initState() {
    super.initState();
    // Add listener to controller to trigger suggestions
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _removeSuggestions();
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.dispose();
    _removeSuggestions();
    super.dispose();
  }

  void _pickAndUploadImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      final url = await widget.onAttachmentSelected(pickedFile.path);
      if (url != null && url.isNotEmpty) {
        final controller = widget.controller;
        final text = controller.text;
        final selection = controller.selection;
        final cursor =
            selection.baseOffset < 0 ? text.length : selection.baseOffset;
        final filename = url.split('/').last;
        final hyperlink = '[$filename]($url)';
        final newText = text.replaceRange(cursor, cursor, hyperlink + ' ');
        controller.value = controller.value.copyWith(
          text: newText,
          selection: TextSelection.collapsed(
              offset: cursor + hyperlink.length + 1),
        );
      }
    }
  }

  // START OF CHANGE: Overhauled logic for both @ and / triggers
  void _onTextChanged() {
    if (!_focusNode.hasFocus) {
      _removeSuggestions();
      return;
    }

    final text = widget.controller.text;
    final selection = widget.controller.selection;

    if (!selection.isValid || selection.baseOffset < 0) {
      _removeSuggestions();
      return;
    }

    final cursorPosition = selection.baseOffset;
    final textBeforeCursor = text.substring(0, cursorPosition);

    // Check for / command trigger
    final slashIndex = textBeforeCursor.lastIndexOf('/');
    if (slashIndex != -1 && (slashIndex == 0 || text[slashIndex - 1] == ' ')) {
      final query = textBeforeCursor.substring(slashIndex + 1);
      if (!query.contains(' ')) { // Only trigger for the command name itself
        final matches = widget.availableCommands
            .where((cmd) => cmd.name.toLowerCase().startsWith(query.toLowerCase()))
            .toList();
        if (matches.isNotEmpty) {
          _showSuggestions(matches, 'command');
          return;
        }
      }
    }

    // Check for @ mention trigger
    final atIndex = textBeforeCursor.lastIndexOf('@');
    if (atIndex != -1 && (atIndex == 0 || text[atIndex - 1] == ' ')) {
      final query = textBeforeCursor.substring(atIndex + 1);
      if (!query.contains(' ')) {
        final matches = widget.allUsernames
            .where((u) => u.toLowerCase().startsWith(query.toLowerCase()))
            .toList();
        if (matches.isNotEmpty) {
          _showSuggestions(matches, 'user');
          return;
        }
      }
    }

    _removeSuggestions();
  }

  void _showSuggestions(List<dynamic> suggestions, String type) {
    _removeSuggestions();
    _suggestions = suggestions;
    _suggestionType = type;
    _selectedSuggestion = 0;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final Size size = renderBox.size;
    final overlay = Overlay.of(context);
    final textFieldOffset = renderBox.localToGlobal(Offset.zero);

    _suggestionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: textFieldOffset.dx + 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + size.height + 8,
        width: size.width - 32,
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF232428),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              itemCount: _suggestions.length,
              itemBuilder: (context, idx) {
                if (_suggestionType == 'user') {
                  final username = _suggestions[idx] as String;
                  return ListTile(
                    dense: true,
                    tileColor: idx == _selectedSuggestion ? Colors.blueGrey[700] : null,
                    title: Text('@$username', style: const TextStyle(color: Colors.white70)),
                    onTap: () => _insertUserSuggestion(username),
                  );
                } else if (_suggestionType == 'command') {
                  final command = _suggestions[idx] as SlashCommand;
                  return ListTile(
                    dense: true,
                    tileColor: idx == _selectedSuggestion ? Colors.blueGrey[700] : null,
                    title: Text('/${command.name}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: Text(command.description, style: const TextStyle(color: Colors.white70)),
                    onTap: () => _insertCommandSuggestion(command.name),
                  );
                }
                return const SizedBox.shrink();
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
    if (mounted) {
        setState(() {
            _suggestions = [];
            _suggestionType = '';
            _selectedSuggestion = 0;
        });
    }
  }

  void _insertUserSuggestion(String username) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final cursor = selection.baseOffset;
    final triggerIndex = text.lastIndexOf('@', cursor - 1);
    if (triggerIndex == -1) return;

    final newText = text.replaceRange(triggerIndex, cursor, '@$username ');
    final newCursor = triggerIndex + username.length + 2;

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _removeSuggestions();
    FocusScope.of(context).requestFocus(_focusNode);
  }

  void _insertCommandSuggestion(String commandName) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final cursor = selection.baseOffset;
    final triggerIndex = text.lastIndexOf('/', cursor - 1);
    if (triggerIndex == -1) return;

    final newText = text.replaceRange(triggerIndex, cursor, '/$commandName ');
    final newCursor = triggerIndex + commandName.length + 2;

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _removeSuggestions();
    FocusScope.of(context).requestFocus(_focusNode);
  }
  // END OF CHANGE

  void _insertEmoji(String emoji) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final cursor = selection.baseOffset;

    final newText = text.replaceRange(cursor, cursor, emoji);
    final newCursor = cursor + emoji.length;

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );

    FocusScope.of(context).requestFocus(_focusNode);
  }

  void _showEmojiPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF232428),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Container(
          height: 250,
          padding: const EdgeInsets.all(12),
          child: GridView.builder(
            itemCount: ircSafeEmojis.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemBuilder: (context, index) {
              final emoji = ircSafeEmojis[index];
              return GestureDetector(
                onTap: () {
                  Navigator.pop(context);
                  _insertEmoji(emoji);
                },
                child: Center(
                  child: Text(
                    emoji,
                    style: const TextStyle(fontSize: 24),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF232428),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Align(
                alignment: Alignment.bottomCenter,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.person, color: Colors.white70),
                      tooltip: "Profile",
                      onPressed: widget.onProfilePressed,
                    ),
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined,
                          color: Colors.white70),
                      tooltip: "Emoji Picker",
                      onPressed: _showEmojiPicker,
                    ),
                    IconButton(
                      icon: const Icon(Icons.attach_file, color: Colors.white70),
                      onPressed: _pickAndUploadImage,
                      tooltip: "Attach Image",
                    ),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: 120,
                        ),
                        child: Scrollbar(
                          child: TextField(
                            controller: widget.controller,
                            focusNode: _focusNode,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: "Send a message...",
                              hintStyle: const TextStyle(
                                  color: Colors.white54, fontSize: 15),
                              filled: true,
                              fillColor: const Color(0xFF383A40),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16.0, vertical: 10.0),
                            ),
                            maxLines: null,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            onEditingComplete: _removeSuggestions,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send, color: Color(0xFF5865F2)),
                      onPressed: () {
                        if (widget.controller.text.isNotEmpty) {
                            widget.onSendMessage();
                        }
                        _removeSuggestions();
                      },
                      tooltip: "Send",
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}