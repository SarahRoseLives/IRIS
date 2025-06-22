import 'package:flutter/material.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import 'user_avatar.dart';
import '../utils/irc_helpers.dart'; // <-- New import for shared IRC role logic

class RightDrawer extends StatelessWidget {
  final List<ChannelMember> members;
  final Map<String, String> userAvatars;

  const RightDrawer({
    super.key,
    required this.members,
    required this.userAvatars,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 240,
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
                    : ListView.builder(
                        itemCount: members.length,
                        itemBuilder: (context, idx) {
                          final member = members[idx];
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
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}