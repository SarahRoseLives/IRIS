import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb
import '../models/channel.dart';
import '../services/websocket_service.dart';
import '../models/user_status.dart';
import '../widgets/user_avatar.dart';

class LeftDrawer extends StatelessWidget {
  final List<String> dms;
  final Map<String, String> userAvatars;
  final Map<String, UserStatus> userStatuses;
  final List<String> joinedChannels;
  final List<String> unjoinedChannels;
  final String selectedConversationTarget;
  final ValueChanged<String> onChannelSelected;
  final ValueChanged<String> onUnjoinedChannelTap;
  final ValueChanged<String> onDmSelected;
  final ValueChanged<String> onRemoveDm;
  final VoidCallback onIrisTap;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;
  final bool showDrawer;
  final VoidCallback onCloseDrawer;
  final bool unjoinedExpanded;
  final VoidCallback onToggleUnjoined;
  final ValueChanged<String> onChannelPart;
  final bool Function(String channelName) hasUnreadMessages;
  final Message? Function(String channelName) getLastMessage;
  final String currentUsername;

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.userAvatars,
    required this.userStatuses,
    required this.joinedChannels,
    required this.unjoinedChannels,
    required this.selectedConversationTarget,
    required this.onChannelSelected,
    required this.onChannelPart,
    required this.onUnjoinedChannelTap,
    required this.onDmSelected,
    required this.onRemoveDm,
    required this.onIrisTap,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
    required this.showDrawer,
    required this.onCloseDrawer,
    required this.unjoinedExpanded,
    required this.onToggleUnjoined,
    required this.hasUnreadMessages,
    required this.getLastMessage,
    required this.currentUsername,
  });

  void _showNewDMDialog(BuildContext context) {
    TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Direct Message'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Enter username'),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Start'),
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Navigator.of(context).pop(controller.text);
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _showDmOptions(BuildContext context, String dmChannelName) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Remove DM', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onRemoveDm(dmChannelName);
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showLeaveDialog(BuildContext context, String channel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Leave $channel?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text('Leave Channel', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onChannelPart(channel);
                  onCloseDrawer();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final sortedDms = List<String>.from(dms)..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 80,
                        color: const Color(0xFF232428),
                        child: SafeArea(
                          child: Column(
                            children: [
                              const SizedBox(height: 20),
                              Tooltip(
                                message: "Channels",
                                child: GestureDetector(
                                  onTap: onIrisTap,
                                  child: CircleAvatar(
                                    radius: 28,
                                    backgroundColor: !selectedConversationTarget.startsWith('@')
                                        ? Colors.white
                                        : const Color(0xFF5865F2),
                                    child: ClipOval(
                                      child: Image.asset(
                                        'assets/images/icon.png', // <-- Replace with your PNG asset path
                                        width: 56,
                                        height: 56,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              const Divider(color: Colors.white24, indent: 20, endIndent: 20),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: sortedDms.length,
                                  itemBuilder: (context, idx) {
                                    final dmChannelName = sortedDms[idx];
                                    final username = dmChannelName.substring(1);
                                    final avatarUrl = userAvatars[username];
                                    final status = userStatuses[username] ?? UserStatus.offline;
                                    final isSelected = selectedConversationTarget.toLowerCase() == dmChannelName.toLowerCase();
                                    final lastMessage = getLastMessage(dmChannelName);
                                    final isUnread = hasUnreadMessages(dmChannelName) &&
                                        (lastMessage != null && lastMessage.from != currentUsername);

                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                                      child: Tooltip(
                                        message: username,
                                        child: GestureDetector(
                                          onTap: () {
                                            onDmSelected(dmChannelName);
                                            onCloseDrawer();
                                          },
                                          onLongPress: () => _showDmOptions(context, dmChannelName),
                                          child: Stack(
                                            alignment: Alignment.center,
                                            clipBehavior: Clip.none,
                                            children: [
                                              UserAvatar(
                                                radius: 28,
                                                username: username,
                                                avatarUrl: avatarUrl,
                                                status: status,
                                                showStatusDot: true,
                                              ),
                                              if (isSelected)
                                                Positioned.fill(
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      border: Border.all(color: Colors.white, width: 3),
                                                    ),
                                                  ),
                                                ),
                                              if (isUnread && !isSelected)
                                                Positioned(
                                                  left: 2,
                                                  child: Container(
                                                    width: 8,
                                                    height: 8,
                                                    decoration: const BoxDecoration(
                                                      color: Colors.white,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: SafeArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                                child: Text(
                                  "Channels",
                                  style: TextStyle(
                                    color: Colors.grey[400],
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  children: [
                                    ...joinedChannels.map((channel) {
                                      final isSelected = selectedConversationTarget.toLowerCase() == channel.toLowerCase();
                                      final lastMessage = getLastMessage(channel);
                                      final isUnread = hasUnreadMessages(channel) &&
                                          (lastMessage != null && lastMessage.from != currentUsername);
                                      // Only show preview if last message is NOT from current user and not null
                                      final bool showSubtitle = lastMessage != null &&
                                          !isSelected &&
                                          isUnread &&
                                          lastMessage.from != currentUsername;
                                      final String? subtitle = showSubtitle
                                          ? '${lastMessage!.from}: ${lastMessage.content}'
                                          : null;

                                      return ChannelListItem(
                                        name: channel,
                                        isSelected: isSelected,
                                        isUnread: isUnread,
                                        subtitle: subtitle,
                                        onTap: () {
                                          onChannelSelected(channel);
                                          onCloseDrawer();
                                        },
                                        onLongPress: () => _showLeaveDialog(context, channel),
                                      );
                                    }).toList(),
                                    if (unjoinedChannels.isNotEmpty)
                                      ExpansionTile(
                                        title: Text(
                                            "Other Channels",
                                            style: TextStyle(
                                                color: Colors.grey[400],
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12)),
                                        iconColor: Colors.grey[400],
                                        collapsedIconColor: Colors.grey[400],
                                        initiallyExpanded: unjoinedExpanded,
                                        onExpansionChanged: (_) => onToggleUnjoined(),
                                        children: unjoinedChannels.map((channel) {
                                          return ChannelListItem(
                                            name: channel,
                                            isSelected: false,
                                            isUnread: false,
                                            onTap: () {
                                              onUnjoinedChannelTap(channel);
                                              onCloseDrawer();
                                            },
                                          );
                                        }).toList(),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Always show the close handle, both web and mobile!
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: Center(
                child: Icon(
                  Icons.chevron_left,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChannelListItem extends StatelessWidget {
  final String name;
  final bool isSelected;
  final bool isUnread;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ChannelListItem({
    Key? key,
    required this.name,
    required this.isSelected,
    required this.isUnread,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool isActive = isSelected || (isUnread && !isSelected);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Material(
        color: isSelected ? const Color(0xFF5865F2).withOpacity(0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(5),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 4,
                height: isUnread && !isSelected ? (subtitle != null ? 36 : 24) : 0,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(4),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white70,
                          fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                          fontSize: 16,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}