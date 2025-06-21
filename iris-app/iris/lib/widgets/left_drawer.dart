import 'package:flutter/material.dart';
import '../services/websocket_service.dart';

class LeftDrawer extends StatelessWidget {
  final List<String> dms;
  final Map<String, String> userAvatars;
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
  final ValueChanged<String> onChannelPart; // <-- ADDED

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.userAvatars,
    required this.joinedChannels,
    required this.unjoinedChannels,
    required this.selectedConversationTarget,
    required this.onChannelSelected,
    required this.onChannelPart, // <-- ADDED
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

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 280,
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
                        // IRIS Icon to return to main channels view
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
                        // DM list
                        Expanded(
                          child: ListView.builder(
                            itemCount: dms.length,
                            itemBuilder: (context, idx) {
                              final dmChannelName = dms[idx];
                              final username = dmChannelName.substring(1);
                              final avatarUrl = userAvatars[username];
                              final isSelected = selectedConversationTarget.toLowerCase() == dmChannelName.toLowerCase();

                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8.0),
                                child: Tooltip(
                                  message: username,
                                  child: GestureDetector(
                                    onTap: () {
                                      onDmSelected(dmChannelName);
                                      onCloseDrawer();
                                    },
                                    child: CircleAvatar(
                                      radius: 28,
                                      backgroundColor: isSelected ? Colors.white : Colors.grey[800],
                                      backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                                          ? NetworkImage(avatarUrl) as ImageProvider
                                          : null,
                                      child: (avatarUrl == null || avatarUrl.isEmpty)
                                          ? Text(
                                              username.isNotEmpty ? username[0].toUpperCase() : '?',
                                              style: TextStyle(
                                                color: isSelected ? Colors.black : Colors.white,
                                                fontWeight: FontWeight.bold))
                                          : null,
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
                        // Joined Channels
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
                                          title: Text('Leave Channel'),
                                          content: Text('Are you sure you want to leave $channel?'),
                                          actions: <Widget>[
                                            TextButton(
                                              child: Text('Cancel'),
                                              onPressed: () => Navigator.of(context).pop(),
                                            ),
                                            TextButton(
                                              child: Text('Leave', style: TextStyle(color: Colors.red)),
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
                                  title: Text(
                                    "Other Channels",
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: null, // Use default arrow, no double arrow
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
    );
  }
}