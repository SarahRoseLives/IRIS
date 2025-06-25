import 'package:flutter/material.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import 'user_avatar.dart';
import '../utils/irc_helpers.dart';

class RightDrawer extends StatelessWidget {
  final List<ChannelMember> members;
  final Map<String, String> userAvatars;
  final VoidCallback onCloseDrawer;

  const RightDrawer({
    super.key,
    required this.members,
    required this.userAvatars,
    required this.onCloseDrawer,
  });

  // Grouping logic for IRC roles
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

  @override
  Widget build(BuildContext context) {
    // Split members into online and away for each role
    final onlineMembers = members.where((m) => !m.isAway).toList();
    final awayMembers = members.where((m) => m.isAway).toList();

    final onlineGroups = _groupByRole(onlineMembers);
    final awayGroups = _groupByRole(awayMembers);

    List<Widget> buildSection(Map<String, List<ChannelMember>> groups, {String? sectionLabel}) {
      final widgets = <Widget>[];
      for (final prefix in _roleOrder) {
        final group = groups[prefix];
        if (group != null && group.isNotEmpty) {
          widgets.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 0, 4),
            child: Text(
              sectionLabel == null
                  ? _roleLabels[prefix]!
                  : "$sectionLabel: ${_roleLabels[prefix]}",
              style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontSize: 13),
            ),
          ));
          group.sort((a, b) => a.nick.toLowerCase().compareTo(b.nick.toLowerCase()));
          widgets.addAll(group.map((member) {
            final avatarUrl = userAvatars[member.nick];
            final status = member.isAway ? UserStatus.away : UserStatus.online;
            final roleColor = getColorForPrefix(member.prefix);
            final roleIcon = getIconForPrefix(member.prefix);

            return ListTile(
              leading: UserAvatar(
                username: member.nick,
                avatarUrl: avatarUrl,
                status: status,
                radius: 16,
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      member.nick,
                      style: TextStyle(
                        color: roleColor,
                        fontWeight: member.prefix.isNotEmpty
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (roleIcon != null) ...[
                    const SizedBox(width: 8),
                    Icon(roleIcon, color: roleColor, size: 16),
                  ]
                ],
              ),
            );
          }));
        }
      }
      return widgets;
    }

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          // Handle on the left side of the right drawer
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
          // Original Drawer Content
          Expanded(
            child: Container(
              color: const Color(0xFF2B2D31),
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        "Members",
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 20),
                      ),
                    ),
                    const Divider(color: Colors.white24, height: 1),
                    Expanded(
                      child: members.isEmpty
                          ? const Center(
                              child: Text(
                                "No members",
                                style: TextStyle(color: Colors.white54),
                              ),
                            )
                          : ListView(
                              children: [
                                ...buildSection(onlineGroups),
                                if (awayMembers.isNotEmpty) ...[
                                  const Padding(
                                    padding: EdgeInsets.fromLTRB(16, 20, 0, 4),
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
            ),
          ),
        ],
      ),
    );
  }
}