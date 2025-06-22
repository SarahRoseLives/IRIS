// main_layout.dart (Modified)
import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // Import provider

import 'viewmodels/main_layout_viewmodel.dart'; // Import the new ViewModel
import 'screens/main_chat_screen.dart'; // Import the new MainChatScreen

class IrisLayout extends StatelessWidget {
  final String username;
  final String? token; // Accept token here

  const IrisLayout({super.key, required this.username, this.token});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      // FIX: Changed 'initialToken' to 'token' to match the updated constructor.
      create: (context) => MainLayoutViewModel(username: username, token: token),
      child: const MainChatScreen(),
    );
  }
}