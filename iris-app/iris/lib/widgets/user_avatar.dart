import 'package:flutter/material.dart';
import '../models/user_status.dart';

class UserAvatar extends StatelessWidget {
  final String username;
  final String? avatarUrl;
  final UserStatus status;
  final double radius;
  final bool showStatusDot; // control showing the status dot

  const UserAvatar({
    super.key,
    required this.username,
    this.avatarUrl,
    required this.status,
    this.radius = 18.0,
    this.showStatusDot = true, // Default: show dot unless disabled
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

    final double dotDiameter = radius * 0.7;
    final double dotBorder = 2.0;
    final double overlap = dotDiameter * 0.25;

    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
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
          if (showStatusDot)
            Positioned(
              right: -(overlap),
              bottom: -(overlap),
              child: Container(
                width: dotDiameter,
                height: dotDiameter,
                decoration: BoxDecoration(
                  color: _getStatusColor(),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: statusBorderColor,
                    width: dotBorder,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}