import 'package:flutter/material.dart';

/// Gets the display color for a user based on their IRC channel prefix.
Color getColorForPrefix(String prefix) {
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

/// Gets the display icon for a user based on their IRC channel prefix.
IconData? getIconForPrefix(String prefix) {
  switch (prefix) {
    case '~':
      return Icons.workspace_premium; // Owner
    case '&':
      return Icons.security; // Admin
    case '@':
      return Icons.shield; // Operator
    case '%':
      return Icons.security_sharp; // Half-op
    case '+':
      return Icons.record_voice_over; // Voiced
    default:
      return null; // No icon for regular members
  }
}