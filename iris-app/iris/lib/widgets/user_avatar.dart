import 'package:flutter/material.dart';
import '../models/user_status.dart';

class UserAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final UserStatus status;
  final double radius;

  const UserAvatar({
    super.key,
    required this.username,
    this.avatarUrl,
    required this.status,
    this.radius = 18.0,
  });

  Color _getStatusColor() {
    switch (status) {
      case UserStatus.online:
        return Colors.green;
      case UserStatus.away:
        return Colors.amber;
      case UserStatus.offline:
      default:
        return Colors.grey.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    // This color is the background of the drawers. It's a close enough
    // match for the main chat area background as well.
    const statusBorderColor = Color(0xFF2B2D31);

    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: const Color(0xFF5865F2),
          backgroundImage: (avatarUrl != null && avatarUrl!.isNotEmpty)
              ? NetworkImage(avatarUrl!)
              : null,
          child: (avatarUrl == null || avatarUrl!.isEmpty)
              ? Text(
                  username.isNotEmpty ? username[0].toUpperCase() : '?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: radius * 0.85,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : null,
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: radius * 0.7,
            height: radius * 0.7,
            decoration: BoxDecoration(
              color: _getStatusColor(),
              shape: BoxShape.circle,
              border: Border.all(
                color: statusBorderColor,
                width: 2.0,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
