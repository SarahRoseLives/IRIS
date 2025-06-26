import 'package:flutter/material.dart';
import '../models/channel.dart'; // Import Message model
import '../services/websocket_service.dart';
import '../models/user_status.dart';
import '../widgets/user_avatar.dart';
import 'package:provider/provider.dart';
import '../viewmodels/main_layout_viewmodel.dart';

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
  final VoidCallback onIrisTap;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;
  final bool showDrawer;
  final VoidCallback onCloseDrawer;
  final bool unjoinedExpanded;
  final VoidCallback onToggleUnjoined;
  final ValueChanged<String> onChannelPart;

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
    required this.onIrisTap,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
    required this.showDrawer,
    required this.onCloseDrawer,
    required this.unjoinedExpanded,
    required this.onToggleUnjoined,
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
                  final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
                  viewModel.startNewDM(controller.text);
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // We need to listen to the view model to get live updates on unread status
    final viewModel = Provider.of<MainLayoutViewModel>(context);
    final sortedDms = List<String>.from(dms)..sort((a,b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: Container(
              color: const Color(0xFF2B2D31),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 80) return Container();
                  return Row(
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
                                    child: const Text(
                                      "IRIS",
                                      style: TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 18),
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
                                    final isUnread = viewModel.chatState.hasUnreadMessages(dmChannelName);

                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                                      child: Tooltip(
                                        message: username,
                                        child: GestureDetector(
                                          onTap: () {
                                            onDmSelected(dmChannelName);
                                            onCloseDrawer();
                                          },
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
                                      final isUnread = viewModel.chatState.hasUnreadMessages(channel);
                                      final lastMessage = viewModel.chatState.getLastMessage(channel);
                                      final bool showSubtitle = isUnread && !isSelected && lastMessage != null;

                                      return ChannelListItem(
                                        name: channel,
                                        isSelected: isSelected,
                                        isUnread: isUnread,
                                        subtitle: showSubtitle ? '${lastMessage.from}: ${lastMessage.content}' : null,
                                        onTap: () {
                                          onChannelSelected(channel);
                                          onCloseDrawer();
                                        },
                                        onLongPress: () => _showLeaveDialog(context, channel),
                                      );
                                    }).toList(),
                                    if (unjoinedChannels.isNotEmpty)
                                      ExpansionTile(
                                        title: Text("Other Channels", style: TextStyle(color: Colors.grey[400], fontWeight: FontWeight.bold, fontSize: 12)),
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
                  );
                },
              ),
            ),
          ),
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: const Center(
                child: Icon(Icons.chevron_left, color: Colors.white54),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLeaveDialog(BuildContext context, String channel) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Leave Channel'),
          content: Text('Are you sure you want to leave $channel?'),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Leave', style: TextStyle(color: Colors.red)),
              onPressed: () {
                Navigator.of(context).pop();
                onChannelPart(channel);
                onCloseDrawer();
              },
            ),
          ],
        );
      },
    );
  }
}

// A dedicated, stateless widget for channel list items to keep the build method clean
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