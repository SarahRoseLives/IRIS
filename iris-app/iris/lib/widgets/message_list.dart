import 'package:flutter/material.dart';
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
                    Text(
                      content,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
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
}
