import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/channel.dart';
import '../models/encryption_session.dart';
import '../utils/irc_helpers.dart';
import 'package:provider/provider.dart';
import '../viewmodels/main_layout_viewmodel.dart';
import '../models/channel_member.dart';

bool isImageUrl(String url) {
  final lower = url.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp');
}

final RegExp markdownLinkRegex =
    RegExp(r'\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)');
final RegExp plainUrlRegex =
    RegExp(r'(https?:\/\/[^\s)]+)');

class MessageList extends StatelessWidget {
  final List<Message> messages;
  final ScrollController scrollController;
  final Map<String, String> userAvatars;
  final String currentUsername;
  // FIX: Added the missing parameter to the constructor.
  final EncryptionStatus encryptionStatus;

  const MessageList({
    Key? key,
    required this.messages,
    required this.scrollController,
    required this.userAvatars,
    required this.currentUsername,
    required this.encryptionStatus, // FIX: It is now part of the constructor.
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final mentionPattern = RegExp(
      r'(?<=^|[^\w@])@?' + RegExp.escape(currentUsername) + r'(?=\b|[^a-zA-Z0-9_])',
      caseSensitive: false,
    );

    final List<ChannelMember> members = context.select<MainLayoutViewModel, List<ChannelMember>>(
      (vm) => vm.members,
    );

    final Map<String, ChannelMember> memberMap = {
      for (final ChannelMember m in members) m.nick: m
    };

    return ListView.builder(
      controller: scrollController,
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];

        if (message.isSystemInfo) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text(
                message.content,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[400], fontStyle: FontStyle.italic),
              ),
            ),
          );
        }

        final contentWidgets = _parseMessageContent(context, message.content);
        final isMention = mentionPattern.hasMatch(message.content);
        ChannelMember? member = memberMap[message.from];
        String prefix = member?.prefix ?? '';
        final roleColor = getColorForPrefix(prefix);
        final roleIcon = getIconForPrefix(prefix);

        final messageColor = message.isEncrypted ? const Color(0xFFC8E6C9) : Colors.white;

        return Container(
          decoration: BoxDecoration(
            color: isMention
                ? const Color(0xFFFFF176).withOpacity(0.45)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(isMention ? 12 : 0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildAvatar(message.from),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (roleIcon != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: Icon(roleIcon, size: 16, color: roleColor),
                          ),
                        if (message.isEncrypted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4.0),
                            child: Icon(Icons.lock, size: 12, color: Colors.greenAccent.withOpacity(0.8)),
                          ),
                        Text(
                          message.from,
                          style: TextStyle(
                            color: roleColor,
                            fontWeight: prefix.isNotEmpty ? FontWeight.bold : FontWeight.normal,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    DefaultTextStyle(
                      style: TextStyle(color: messageColor, fontSize: 15),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: contentWidgets,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAvatar(String from) {
    final avatarUrl = userAvatars[from];
    final initial = (from.isNotEmpty) ? from[0].toUpperCase() : "?";
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
    final fallbackBg = const Color(0xFF5865F2);

    return CircleAvatar(
      radius: 18,
      backgroundColor: hasAvatar ? Colors.transparent : fallbackBg,
      backgroundImage: hasAvatar ? NetworkImage(avatarUrl!) : null,
      child: !hasAvatar
          ? Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            )
          : null,
    );
  }

  List<Widget> _parseMessageContent(BuildContext context, String text) {
    final widgets = <Widget>[];
    String remaining = text;
    final shownImages = <String>{};
    final shownLinks = <String>{};

    while (true) {
      final match = markdownLinkRegex.firstMatch(remaining);
      if (match == null) break;
      final before = remaining.substring(0, match.start);
      if (before.isNotEmpty) {
        widgets.addAll(_parsePlainTextWithUrls(context, before, shownImages, shownLinks));
      }
      final label = match.group(1) ?? '';
      final url = match.group(2) ?? '';
      if (isImageUrl(url) && !shownImages.contains(url)) {
        widgets.add(_tappableImage(context, url));
        shownImages.add(url);
      } else if (!shownLinks.contains(url)) {
        widgets.add(_hyperlinkWidget(context, label, url));
        shownLinks.add(url);
      }
      remaining = remaining.substring(match.end);
    }

    if (remaining.isNotEmpty) {
      widgets.addAll(_parsePlainTextWithUrls(context, remaining, shownImages, shownLinks));
    }

    if (widgets.isEmpty) {
       widgets.add(const SizedBox(height: 1, width: 0,));
    }

    return widgets;
  }

  List<Widget> _parsePlainTextWithUrls(BuildContext context, String text, Set<String> shownImages, Set<String> shownLinks) {
    final widgets = <Widget>[];
    int lastEnd = 0;
    for (final match in plainUrlRegex.allMatches(text)) {
      if (match.start > lastEnd) {
        widgets.add(_textWidget(text.substring(lastEnd, match.start)));
      }
      final url = match.group(0)!;
      if (isImageUrl(url) && !shownImages.contains(url)) {
        widgets.add(_tappableImage(context, url));
        shownImages.add(url);
      } else if (!shownLinks.contains(url)) {
        widgets.add(_hyperlinkWidget(context, url, url));
        shownLinks.add(url);
      }
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      widgets.add(_textWidget(text.substring(lastEnd)));
    }
    return widgets;
  }

  Widget _textWidget(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return SelectableText(text);
  }

  Widget _hyperlinkWidget(BuildContext context, String label, String url) {
    final isImg = isImageUrl(url);
    return InkWell(
      onTap: () async {
        if (isImg) {
          _showImagePreview(context, url);
        } else {
          if (await canLaunchUrl(Uri.parse(url))) {
            await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          }
        }
      },
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.blueAccent,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _tappableImage(BuildContext context, String url) {
    return GestureDetector(
      onTap: () => _showImagePreview(context, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Image.network(
          url,
          height: 180,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
        ),
      ),
    );
  }

  void _showImagePreview(BuildContext context, String url) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Stack(
            children: [
              Container(color: Colors.black.withOpacity(0.8)),
              Center(
                child: InteractiveViewer(
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image, color: Colors.white, size: 64),
                  ),
                ),
              ),
              Positioned(
                top: 40,
                right: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 32),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}