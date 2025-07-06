import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/channel_member.dart';
import '../models/user_status.dart';
import '../utils/irc_helpers.dart';
import '../viewmodels/main_layout_viewmodel.dart';
import 'user_avatar.dart';
import '../models/channel.dart';

class RightDrawer extends StatelessWidget {
  final List<ChannelMember> members;
  final Map<String, String> userAvatars;
  final VoidCallback onCloseDrawer;
  final bool isDrawer;

  const RightDrawer({
    super.key,
    required this.members,
    required this.userAvatars,
    required this.onCloseDrawer,
    this.isDrawer = true,
  });

  static const _roleOrder = [
    '~', // Owner
    '&', // Admin
    '@', // Op
    '%', // Halfop
    '+', // Voice
    '', // Regular
  ];

  static const _roleLabels = {
    '~': "Owners",
    '&': "Admins",
    '@': "Operators",
    '%': "Half-ops",
    '+': "Voiced",
    '': "Members",
  };

  Map<String, List<ChannelMember>> _groupByRole(List<ChannelMember> users) {
    final map = <String, List<ChannelMember>>{};
    for (final member in users) {
      final prefix = member.prefix;
      map.putIfAbsent(prefix, () => []).add(member);
    }
    return map;
  }

  void _showMemberOptions(BuildContext context, String username) {
    final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.message, color: Colors.white),
                title: const Text('Send Direct Message',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  viewModel.startNewDM(username);
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

  Widget buildStyledMemberTile(BuildContext context, ChannelMember member, Map<String, String> userAvatars) {
    final avatarUrl = userAvatars[member.nick];
    final status = member.isAway ? UserStatus.away : UserStatus.online;
    final color = getColorForPrefix(member.prefix);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Material(
        color: const Color(0xFF23262B),
        elevation: 0,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onLongPress: () => _showMemberOptions(context, member.nick),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              children: [
                UserAvatar(
                  username: member.nick,
                  avatarUrl: avatarUrl,
                  status: status,
                  radius: 24,
                  showStatusDot: true,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              member.nick,
                              style: TextStyle(
                                color: color,
                                fontWeight: member.prefix.isNotEmpty ? FontWeight.bold : FontWeight.normal,
                                fontSize: 16,
                                letterSpacing: 0.1,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (member.prefix.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(
                                getIconForPrefix(member.prefix),
                                color: color,
                                size: 18,
                              ),
                            ),
                        ],
                      ),
                      if (member.isAway)
                        const Padding(
                          padding: EdgeInsets.only(top: 2.0),
                          child: Text(
                            "away",
                            style: TextStyle(color: Colors.amber, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Widget _circleHeaderButton(IconData icon, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF23262B),
          border: Border.all(color: Colors.white10, width: 1.5),
        ),
        child: Icon(icon, color: Colors.white70, size: 26),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
    final channelName = viewModel.selectedConversationTarget;
    final channel = viewModel.chatState.channels
        .firstWhere((c) => c.name == channelName, orElse: () => Channel(name: '', members: []));
    final channelTopic = channel.topic ?? '';

    // Group members
    final onlineMembers = members.where((m) => !m.isAway).toList();
    final awayMembers = members.where((m) => m.isAway).toList();
    final onlineGroups = _groupByRole(onlineMembers);
    final awayGroups = _groupByRole(awayMembers);

    final panelHeader = Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Center(
            child: Text(
              channelName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: 0.2,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          if (channelTopic.isNotEmpty)
            Center(
              child: Text(
                channelTopic,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 15,
                  fontWeight: FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          if (channelTopic.isNotEmpty)
            const SizedBox(height: 22),
          if (channelTopic.isEmpty)
            const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _circleHeaderButton(Icons.search, "Search"),
              const SizedBox(width: 16),
              _circleHeaderButton(Icons.forum_outlined, "Threads"),
              const SizedBox(width: 16),
              _circleHeaderButton(Icons.notifications_off_outlined, "Mute"),
              const SizedBox(width: 16),
              _circleHeaderButton(Icons.settings, "Settings"),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );

    List<Widget> buildSection(Map<String, List<ChannelMember>> groups, {String? sectionLabel}) {
      final widgets = <Widget>[];
      for (final prefix in _roleOrder) {
        final group = groups[prefix];
        if (group != null && group.isNotEmpty) {
          widgets.add(Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 0, 4),
            child: Text(
              sectionLabel == null
                  ? _roleLabels[prefix]!
                  : "$sectionLabel: ${_roleLabels[prefix]}",
              style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 14),
            ),
          ));
          group.sort((a, b) => a.nick.toLowerCase().compareTo(b.nick.toLowerCase()));
          widgets.addAll(group.map((member) => buildStyledMemberTile(context, member, userAvatars)));
        }
      }
      return widgets;
    }

    final panelContent = Container(
      color: const Color(0xFF2B2D31),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            panelHeader,
            const Divider(color: Colors.white24, height: 1, thickness: 0.5),
            Expanded(
              child: members.isEmpty
                  ? const Center(
                      child: Text(
                        "No members",
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(top: 12, bottom: 0),
                      children: [
                        ...buildSection(onlineGroups),
                        if (awayMembers.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 26, 0, 4),
                            child: Text(
                              "Away",
                              style: TextStyle(
                                  color: Colors.white60,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14),
                            ),
                          ),
                          ...buildSection(awayGroups, sectionLabel: "Away"),
                        ]
                      ],
                    ),
            ),
          ],
        ),
      ),
    );

    if (!isDrawer) {
      return panelContent;
    }

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: const Center(
                child: Icon(
                  Icons.chevron_right,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
          Expanded(child: panelContent),
        ],
      ),
    );
  }
}