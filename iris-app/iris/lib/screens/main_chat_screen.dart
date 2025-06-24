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
          body: GestureDetector(
            // Top-level GestureDetector captures all horizontal swipes
            onHorizontalDragUpdate: (details) {
              final width = MediaQuery.of(context).size.width;
              // Swipe from left edge to open left drawer
              if (details.delta.dx > 5 && details.globalPosition.dx < 50) {
                if (!viewModel.showLeftDrawer && !viewModel.showRightDrawer) {
                  viewModel.toggleLeftDrawer();
                }
              }
              // Swipe from right edge to open right drawer
              else if (details.delta.dx < -5 &&
                      details.globalPosition.dx > width - 50) {
                if (!viewModel.showLeftDrawer && !viewModel.showRightDrawer) {
                  viewModel.toggleRightDrawer();
                }
              }
              // Swipe left to close left drawer
              else if (viewModel.showLeftDrawer && details.delta.dx < -5) {
                viewModel.toggleLeftDrawer();
              }
              // Swipe right to close right drawer
              else if (viewModel.showRightDrawer && details.delta.dx > 5) {
                viewModel.toggleRightDrawer();
              }
            },
            child: Stack(
              children: [
                // Main content area
                SafeArea(
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
                        child: GestureDetector(
                          onTap: () {
                            if (viewModel.showLeftDrawer) viewModel.toggleLeftDrawer();
                            if (viewModel.showRightDrawer) viewModel.toggleRightDrawer();
                          },
                          child: MessageList(
                            messages: viewModel.currentChannelMessages,
                            scrollController: viewModel.scrollController,
                            userAvatars: viewModel.userAvatars,
                          ),
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
                        onAttachmentSelected: viewModel.uploadAttachment,
                      ),
                    ],
                  ),
                ),

                // Left Drawer
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    opacity: viewModel.showLeftDrawer ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !viewModel.showLeftDrawer,
                      child: LeftDrawer(
                        dms: viewModel.dmChannelNames,
                        userAvatars: viewModel.userAvatars,
                        userStatuses: viewModel.chatState.userStatuses,
                        joinedChannels: viewModel.joinedPublicChannelNames,
                        unjoinedChannels: viewModel.unjoinedPublicChannelNames,
                        selectedConversationTarget: viewModel.selectedConversationTarget,
                        onChannelSelected: viewModel.onChannelSelected,
                        onChannelPart: viewModel.partChannel,
                        onUnjoinedChannelTap: viewModel.onUnjoinedChannelTap,
                        onDmSelected: viewModel.onDmSelected,
                        onIrisTap: viewModel.selectMainView,
                        loadingChannels: viewModel.loadingChannels,
                        error: viewModel.channelError,
                        wsStatus: viewModel.wsStatus,
                        showDrawer: viewModel.showLeftDrawer,
                        onCloseDrawer: viewModel.toggleLeftDrawer,
                        unjoinedExpanded: viewModel.unjoinedChannelsExpanded,
                        onToggleUnjoined: viewModel.toggleUnjoinedChannelsExpanded,
                      ),
                    ),
                  ),
                ),

                // Right Drawer
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    opacity: viewModel.showRightDrawer ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !viewModel.showRightDrawer,
                      child: RightDrawer(
                        members: viewModel.members,
                        userAvatars: viewModel.userAvatars,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}