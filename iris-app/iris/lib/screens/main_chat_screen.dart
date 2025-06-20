import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../viewmodels/main_layout_viewmodel.dart';
import '../widgets/left_drawer.dart';
import '../widgets/right_drawer.dart';
import '../widgets/message_list.dart';
import '../widgets/message_input.dart';
import '../screens/profile_screen.dart';

class MainChatScreen extends StatelessWidget {
  const MainChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainLayoutViewModel>(
      builder: (context, viewModel, child) {
        return Scaffold(
          backgroundColor: const Color(0xFF313338),
          body: Row(
            children: [
              LeftDrawer(
                dms: viewModel.dmChannelNames,
                userAvatars: viewModel.userAvatars,
                channels: viewModel.publicChannelNames,
                selectedConversationTarget: viewModel.selectedConversationTarget,
                onChannelSelected: viewModel.onChannelSelected,
                onDmSelected: viewModel.onDmSelected,
                onIrisTap: viewModel.selectMainView,
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
                                viewModel.selectedConversationTarget,
                                style: const TextStyle(color: Colors.white, fontSize: 20),
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.people, color: Colors.white70),
                              tooltip: "Open Members Drawer",
                              onPressed: viewModel.toggleRightDrawer,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: MessageList(
                          messages: viewModel.currentChannelMessages,
                          scrollController: viewModel.scrollController,
                          userAvatars: viewModel.userAvatars,
                        ),
                      ),
                      MessageInput(
                        controller: viewModel.msgController,
                        onSendMessage: viewModel.handleSendMessage,
                        onProfilePressed: () {
                          if (viewModel.token != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ProfileScreen(authToken: viewModel.token!),
                              ),
                            );
                          }
                        },
                        onAttachmentSelected: viewModel.uploadAttachment, // <-- Added this line
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