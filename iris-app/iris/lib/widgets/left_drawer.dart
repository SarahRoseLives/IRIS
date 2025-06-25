import 'package:flutter/material.dart';
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
    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          // Drawer Content
          Expanded(
            child: Container(
              color: const Color(0xFF2B2D31),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 80) {
                    return Container();
                  }
                  return Row(
                    children: [
                      // DM Avatars Bar
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
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8.0),
                                child: Tooltip(
                                  message: "New Direct Message",
                                  child: GestureDetector(
                                    onTap: () {
                                      onCloseDrawer();
                                      _showNewDMDialog(context);
                                    },
                                    child: CircleAvatar(
                                      radius: 28,
                                      backgroundColor: const Color(0xFF2B2D31),
                                      child: Icon(
                                        Icons.add,
                                        color: Colors.greenAccent[400],
                                        size: 32,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const Divider(color: Colors.white24, indent: 20, endIndent: 20),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: dms.length,
                                  itemBuilder: (context, idx) {
                                    final dmChannelName = dms[idx];
                                    final username = dmChannelName.substring(1);
                                    final avatarUrl = userAvatars[username];
                                    final status = userStatuses[username] ?? UserStatus.offline;

                                    return Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                                      child: Tooltip(
                                        message: username,
                                        child: GestureDetector(
                                          onTap: () {
                                            onDmSelected(dmChannelName);
                                            onCloseDrawer();
                                          },
                                          child: UserAvatar(
                                            radius: 28,
                                            username: username,
                                            avatarUrl: avatarUrl,
                                            status: status,
                                            showStatusDot: false,
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
                      // Channel List Panel
                      Expanded(
                        child: SafeArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 16, 0, 8),
                                child: Text(
                                  "Joined Channels",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    ...joinedChannels.map((channel) {
                                      final isSelected = selectedConversationTarget == channel;
                                      return ListTile(
                                        title: Text(
                                          channel,
                                          style: TextStyle(
                                            color: isSelected ? Colors.white : Colors.white70,
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                          ),
                                        ),
                                        selected: isSelected,
                                        onTap: () {
                                          onChannelSelected(channel);
                                          onCloseDrawer();
                                        },
                                        onLongPress: () {
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
                                        },
                                      );
                                    }).toList(),
                                    if (unjoinedChannels.isNotEmpty)
                                      ExpansionTile(
                                        initiallyExpanded: unjoinedExpanded,
                                        onExpansionChanged: (_) => onToggleUnjoined(),
                                        title: const Text(
                                          "Other Channels",
                                          style: TextStyle(
                                            color: Colors.white70,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        trailing: null,
                                        children: unjoinedChannels.map((channel) {
                                          return ListTile(
                                            title: Text(
                                              channel,
                                              style: const TextStyle(color: Colors.white54),
                                            ),
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
          // Handle on the right side
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: const Center(
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