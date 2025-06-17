// widgets/message_list.dart
import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart'; // Or any other theme you prefer
import 'package:flutter_highlight/themes/atom-one-light.dart'; // Example for light theme
import '../config.dart'; // Import config to get apiHost and apiPort

import 'link_preview.dart';

class MessageList extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final ScrollController scrollController;
  final Map<String, String> userAvatars;

  const MessageList({
    super.key,
    required this.messages,
    required this.scrollController,
    required this.userAvatars,
  });

  // Helper to get the avatar URL, returning null if no valid URL is found/stored
  String? _getDisplayAvatarUrl(String username) {
    final storedAvatarUrl = userAvatars[username];

    // If the map contains an entry for the username and it's not an empty string, use it.
    if (storedAvatarUrl != null && storedAvatarUrl.isNotEmpty) {
      return storedAvatarUrl;
    }

    // If the map contains the username but its value is empty (meaning no avatar found after check),
    // or if the username is not in the map yet (meaning no check has been made),
    // we can construct a potential URL to trigger a load attempt.
    // However, the `_loadAvatarForUser` in `main_layout` is already doing the `HEAD` request.
    // So here, we should only return a URL if `main_layout` has *confirmed` one.
    // Otherwise, we return null to show the initial.

    // Given `_userAvatars[username] = '';` in main_layout if not found:
    // If `storedAvatarUrl` is `null` (not in map) or `''` (no avatar found), we return `null`.
    return null; // Return null to indicate no displayable avatar URL directly from this helper.
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.all(16.0),
      itemCount: messages.length,
      itemBuilder: (context, idx) {
        final message = messages[idx];
        final content = message['content'] ?? '';
        final sender = message['from']?.toString() ?? 'Unknown';
        // You can optionally retrieve the message ID here if needed for debugging or future features
        // final String? messageId = message['id']?.toString();

        // Get the confirmed displayable avatar URL. This will be null if no avatar is found.
        final String? displayAvatarUrl = _getDisplayAvatarUrl(sender);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFF5865F2),
                radius: 18,
                // If displayAvatarUrl is NOT null, use it as backgroundImage
                backgroundImage: displayAvatarUrl != null
                    ? NetworkImage(displayAvatarUrl) as ImageProvider<Object>?
                    : null, // Otherwise, set backgroundImage to null
                // If displayAvatarUrl IS null, show the text initial as child
                child: displayAvatarUrl == null
                    ? Text(
                        sender.isNotEmpty
                            ? sender[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                      )
                    : null, // No child if image is being displayed
                // onBackgroundImageError is only relevant if backgroundImage is NOT null
                onBackgroundImageError: displayAvatarUrl != null
                    ? (exception, stackTrace) {
                        // This indicates a network image load failed *after* a URL was provided.
                        // This shouldn't happen often if _loadAvatarForUser does its job (HEAD request).
                        // If it does, the CircleAvatar will show an empty circle (because background is null, child is null)
                        // A more advanced solution would be to notify parent to remove this user's avatar from map
                        // so it falls back to initial on next rebuild.
                        print('CRITICAL: Error loading confirmed avatar for $sender from $displayAvatarUrl: $exception');
                      }
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
                          sender,
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
                                          .substring(11, 16) ??
                                      ''
                              : '',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                    RichText(
                      text: TextSpan(
                        children: _buildMessageSpans(content),
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                    ..._extractLinks(content).map((url) => LinkPreview(url: url)),
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
              language: language,
              theme: atomOneDarkTheme,
              textStyle: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14.0,
              ),
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