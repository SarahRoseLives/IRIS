// main_layout.dart

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'viewmodels/main_layout_viewmodel.dart';
import 'screens/main_chat_screen.dart';
import 'package:get_it/get_it.dart';
import 'controllers/chat_controller.dart'; // Correct import path

class irisLayout extends StatelessWidget {
  final String username;
  final String? token;
  final ChatController chatController; // Accept ChatController directly

  const irisLayout({
    super.key,
    required this.username,
    this.token,
    required this.chatController, // Require it in constructor
  });

  @override
  Widget build(BuildContext context) {
    // The ChatController is now passed in, so we know it's ready.
    // No need for a GetIt.instance.isRegistered<ChatController>() check here.

    return ChangeNotifierProvider(
      create: (context) => MainLayoutViewModel(
        username: username,
        token: token,
        chatController: chatController, // Pass it to ViewModel
      ),
      child: const MainChatScreen(),
    );
  }
}