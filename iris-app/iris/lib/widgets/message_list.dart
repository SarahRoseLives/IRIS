// lib/widgets/message_list.dart
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import '../models/channel.dart'; // Import the Message class
import 'link_preview.dart';

class MessageList extends StatelessWidget {
  // MODIFIED: This now accepts a list of strongly-typed Message objects.
  final List<Message> messages;
  final ScrollController scrollController;
  final Map<String, String> userAvatars;

  const MessageList({
    super.key,
    required this.messages,
    required this.scrollController,
    required this.userAvatars,
  });

  String? _getDisplayAvatarUrl(String username) {
    final storedAvatarUrl = userAvatars[username];
    if (storedAvatarUrl != null && storedAvatarUrl.isNotEmpty) {
      return storedAvatarUrl;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16.0),
      itemCount: messages.length,
      itemBuilder: (context, idx) {
        // MODIFIED: Use the Message object directly.
        final message = messages[idx];
        final String? displayAvatarUrl = _getDisplayAvatarUrl(message.from);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFF5865F2),
                radius: 18,
                backgroundImage: displayAvatarUrl != null ? NetworkImage(displayAvatarUrl) : null,
                child: displayAvatarUrl == null
                    ? Text(
                        message.from.isNotEmpty ? message.from[0].toUpperCase() : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          message.from, // Use message property
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          // Format the DateTime object from the message
                          '${message.time.hour.toString().padLeft(2, '0')}:${message.time.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                    RichText(
                      text: TextSpan(
                        children: _buildMessageSpans(message.content), // Use message property
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    ..._extractLinks(message.content).map((url) => LinkPreview(url: url)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<String> _extractLinks(String text) {
    final regex = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    return regex.allMatches(text).map((m) => m.group(0)!).toList();
  }

  List<InlineSpan> _buildMessageSpans(String content) {
    final List<InlineSpan> spans = [];
    final codeBlockRegex = RegExp(r'```(\w+)?\n([\s\S]*?)\n```');
    int lastMatchEnd = 0;

    for (RegExpMatch match in codeBlockRegex.allMatches(content)) {
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(text: content.substring(lastMatchEnd, match.start)));
      }

      final language = match.group(1);
      final code = match.group(2)!;

      spans.add(
        WidgetSpan(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(5.0),
            ),
            child: HighlightView(
              code,
              language: language ?? 'plaintext',
              theme: atomOneDarkTheme,
              textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14.0),
            ),
          ),
        ),
      );
      lastMatchEnd = match.end;
    }

    if (lastMatchEnd < content.length) {
      spans.add(TextSpan(text: content.substring(lastMatchEnd)));
    }

    return spans;
  }
}
