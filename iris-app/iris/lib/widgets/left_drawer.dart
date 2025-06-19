// widgets/left_drawer.dart
import 'package:flutter/material.dart';
import '../services/websocket_service.dart';
import 'channel_panel.dart';

class LeftDrawer extends StatelessWidget {
  final List<String> dms;
  final Map<String, String> userAvatars;
  final List<String> channels;
  final String selectedConversationTarget;
  final ValueChanged<String> onChannelSelected;
  final ValueChanged<String> onDmSelected;
  final VoidCallback onIrisTap;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;
  final bool showDrawer;

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.userAvatars,
    required this.channels,
    required this.selectedConversationTarget,
    required this.onChannelSelected,
    required this.onDmSelected,
    required this.onIrisTap,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
    required this.showDrawer,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      width: showDrawer ? 280 : 0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      color: const Color(0xFF2B2D31),
      clipBehavior: Clip.hardEdge,
      alignment: Alignment.topLeft,
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
                            final dmChannelName = dms[idx]; // e.g., '@bob'
                            final username = dmChannelName.substring(1);
                            final avatarUrl = userAvatars[username];
                            final isSelected = selectedConversationTarget.toLowerCase() == dmChannelName.toLowerCase();

                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Tooltip(
                                message: username,
                                child: GestureDetector(
                                  onTap: () => onDmSelected(dmChannelName),
                                 child: CircleAvatar(
                                      radius: 28,
                                      backgroundColor: isSelected ? Colors.white : Colors.grey[800],
                                      backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                                          ? NetworkImage(avatarUrl) as ImageProvider
                                          : null,
                                      child: (avatarUrl == null || avatarUrl.isEmpty)
                                          ? Text(
                                              username.isNotEmpty ? username[0].toUpperCase() : '?',
                                              style: TextStyle( // FIX: Removed 'const'
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
                child: ChannelPanel(
                  channels: channels,
                  selectedConversationTarget: selectedConversationTarget,
                  onChannelSelected: onChannelSelected,
                  loadingChannels: loadingChannels,
                  error: error,
                  wsStatus: wsStatus,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
