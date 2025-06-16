// widgets/message_list.dart
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart'; // Or any other theme you prefer
import 'package:flutter_highlight/themes/atom-one-light.dart'; // Example for light theme

import 'link_preview.dart';

class MessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final ScrollController scrollController;

  const MessageList({
    super.key,
    required this.messages,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16.0),
      itemCount: messages.length,
      itemBuilder: (context, idx) {
        final message = messages[idx];
        final content = message['content'] ?? '';
        final links = _extractLinks(content);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFF5865F2),
                radius: 18,
                child: Text(
                  message['from']?.toString().isNotEmpty == true
                      ? message['from'][0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          message['from'] ?? 'Unknown',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          (message['time'] != null && message['time'] is String)
                              ? DateTime.tryParse(message['time'])
                                    ?.toLocal()
                                    .toString()
                                    .split('.')[0]
                                    .substring(11, 16) ?? ''
                              : '',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                    // This is the crucial part that uses RichText and _buildMessageSpans
                    RichText(
                      text: TextSpan(
                        children: _buildMessageSpans(content),
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    ...links.map((url) => LinkPreview(url: url)),
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
    final regex = RegExp(
      r'(https?:\/\/[^\s]+)',
      caseSensitive: false,
    );
    return regex.allMatches(text).map((m) => m.group(0)!).toList();
  }

  List<InlineSpan> _buildMessageSpans(String content) {
    final List<InlineSpan> spans = [];
    // This regex looks for newlines after the opening ``` and before the closing ```
    final codeBlockRegex = RegExp(r'```(\w+)?\n([\s\S]*?)\n```');
    int lastMatchEnd = 0;

    for (RegExpMatch match in codeBlockRegex.allMatches(content)) {
      // Add text before the current code block
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(text: content.substring(lastMatchEnd, match.start)));
      }

      final language = match.group(1); // e.g., 'python'
      final code = match.group(2)!;

      spans.add(
        WidgetSpan(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 8.0),
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4), // Dark background for code
              borderRadius: BorderRadius.circular(5.0),
            ),
            child: HighlightView(
              code,
              language: language,
              theme: atomOneDarkTheme, // Use a dark theme (you can change this)
              textStyle: const TextStyle(
                fontFamily: 'monospace', // Monospace font for code
                fontSize: 14.0,
              ),
            ),
          ),
        ),
      );
      lastMatchEnd = match.end;
    }

    // Add any remaining text after the last code block
    if (lastMatchEnd < content.length) {
      spans.add(TextSpan(text: content.substring(lastMatchEnd)));
    }

    return spans;
  }
}