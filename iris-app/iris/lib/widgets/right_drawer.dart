import 'package:flutter/material.dart';
import '../models/channel_member.dart'; // Import the new model

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
        return Colors.amber; // Owner
      case '@':
        return Colors.redAccent; // Operator
      case '+':
        return Colors.lightGreen; // Voiced
      default:
        return Colors.white70; // Regular member
    }
  }

  // Helper to get an icon for the user's prefix
  IconData _getIconForPrefix(String prefix) {
    switch (prefix) {
      case '~':
        return Icons.shield; // Owner
      case '@':
        return Icons.star; // Operator
      case '+':
        return Icons.volume_up; // Voiced
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
                child: ListView.builder(
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