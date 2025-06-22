import 'package:flutter/material.dart';
import '../models/channel_member.dart';

class RightDrawer extends StatelessWidget {
  final List<ChannelMember> members;

  const RightDrawer({
    super.key,
    required this.members,
  });

  // Helper to determine the color based on the user's prefix
  Color _getColorForPrefix(String prefix) {
    switch (prefix) {
      case '~':
        return Colors.deepPurpleAccent; // Owner
      case '&':
        return Colors.redAccent; // Admin
      case '@':
        return Colors.amber; // Operator
      case '%':
        return Colors.blue; // Half-op
      case '+':
        return Colors.greenAccent; // Voiced
      default:
        return Colors.white; // Regular member
    }
  }

  // Helper to get an icon for the user's prefix
  IconData _getIconForPrefix(String prefix) {
    switch (prefix) {
      case '~':
        return Icons.workspace_premium; // Owner
      case '&':
        return Icons.security; // Admin
      case '@':
        return Icons.shield; // Operator
      case '%':
        return Icons.security; // Half-op (replacing moderator with security)
      case '+':
        return Icons.record_voice_over; // Voiced
      default:
        return Icons.person; // Regular member
    }
  }

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
                        return ListTile(
                          leading: Icon(
                            _getIconForPrefix(member.prefix),
                            color: _getColorForPrefix(member.prefix),
                            size: 20,
                          ),
                          title: Text(
                            member.nick,
                            style: TextStyle(
                              color: _getColorForPrefix(member.prefix),
                              fontWeight: member.prefix.isNotEmpty
                                  ? FontWeight.bold
                                  : FontWeight.normal,
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
    );
  }
}