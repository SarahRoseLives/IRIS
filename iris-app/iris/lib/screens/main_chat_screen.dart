// lib/screens/main_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/main_layout_viewmodel.dart';
import '../widgets/left_drawer.dart';
import '../widgets/right_drawer.dart';
import '../widgets/message_list.dart';
import '../widgets/message_input.dart';
import '../screens/profile_screen.dart'; // Import ProfileScreen

class MainChatScreen extends StatelessWidget {
  const MainChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainLayoutViewModel>(
      builder: (context, viewModel, child) {
        final List<Map<String, dynamic>> currentChannelMessages =
            viewModel.channels.isNotEmpty && viewModel.selectedChannelIndex < viewModel.channels.length
                ? viewModel.channelMessages[viewModel.channels[viewModel.selectedChannelIndex]] ?? []
                : [];

        return Scaffold(
          backgroundColor: const Color(0xFF313338),
          body: Row(
            children: [
              LeftDrawer(
                dms: viewModel.dms,
                channels: viewModel.channels,
                selectedChannelIndex: viewModel.selectedChannelIndex,
                onChannelSelected: viewModel.onChannelSelected,
                loadingChannels: viewModel.loadingChannels,
                error: viewModel.channelError,
                wsStatus: viewModel.wsStatus,
                showDrawer: viewModel.showLeftDrawer,
              ),
              Expanded(
                child: SafeArea(
                  child: Column(
                    children: [
                      Container(
                        color: const Color(0xFF232428),
                        height: 56,
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.menu, color: Colors.white54),
                              tooltip: "Open Channels Drawer",
                              onPressed: viewModel.toggleLeftDrawer,
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Text(
                                viewModel.channels.isNotEmpty && viewModel.selectedChannelIndex < viewModel.channels.length
                                    ? viewModel.channels[viewModel.selectedChannelIndex]
                                    : "#loading",
                                style: const TextStyle(color: Colors.white, fontSize: 20),
                              ),
                            ),
                            const Spacer(),
                            if (viewModel.token != null)
                              IconButton(
                                icon: const Icon(Icons.person, color: Colors.white70),
                                tooltip: "Profile",
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => ProfileScreen(authToken: viewModel.token!),
                                    ),
                                  );
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.people, color: Colors.white70),
                              tooltip: "Open Members Drawer",
                              onPressed: viewModel.toggleRightDrawer,
                            ),
                            IconButton(
                              icon: const Icon(Icons.logout, color: Colors.white70),
                              tooltip: "Logout",
                              onPressed: () => viewModel.showJoinChannelDialog(context), // Use the dialog here
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: MessageList(
                          messages: currentChannelMessages,
                          scrollController: viewModel.scrollController,
                          userAvatars: viewModel.userAvatars,
                        ),
                      ),
                      MessageInput(
                        controller: viewModel.msgController,
                        onSendMessage: viewModel.handleSendMessage,
                      ),
                    ],
                  ),
                ),
              ),
              if (viewModel.showRightDrawer)
                RightDrawer(members: viewModel.members),
            ],
          ),
        );
      },
    );
  }
}