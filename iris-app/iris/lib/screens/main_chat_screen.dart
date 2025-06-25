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
    // Define drawer widths for animation positioning
    const double leftDrawerWidth = 280;
    const double rightDrawerWidth = 240;

    return Consumer<MainLayoutViewModel>(
      builder: (context, viewModel, child) {
        final Set<String> allUsernames = {
          ...viewModel.members.map((m) => m.nick),
          ...viewModel.currentChannelMessages.map((m) => m.from),
        };

        return Scaffold(
          backgroundColor: const Color(0xFF313338),
          body: GestureDetector(
            // This detector handles swiping from the edges to OPEN drawers
            // and swiping on the drawers themselves to CLOSE them.
            onHorizontalDragUpdate: (details) {
              final width = MediaQuery.of(context).size.width;
              // Swipe right from left edge to open left drawer
              if (details.delta.dx > 5 && details.globalPosition.dx < 50) {
                if (!viewModel.showLeftDrawer && !viewModel.showRightDrawer) {
                  viewModel.toggleLeftDrawer();
                }
              }
              // Swipe left from right edge to open right drawer
              else if (details.delta.dx < -5 &&
                  details.globalPosition.dx > width - 50) {
                if (!viewModel.showLeftDrawer && !viewModel.showRightDrawer) {
                  viewModel.toggleRightDrawer();
                }
              }
              // Swipe left on an open left drawer to close it
              else if (viewModel.showLeftDrawer && details.delta.dx < -5) {
                viewModel.toggleLeftDrawer();
              }
              // Swipe right on an open right drawer to close it
              else if (viewModel.showRightDrawer && details.delta.dx > 5) {
                viewModel.toggleRightDrawer();
              }
            },
            child: Stack(
              children: [
                // --- Main Content Area ---
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
                        child: MessageList(
                          messages: viewModel.currentChannelMessages,
                          scrollController: viewModel.scrollController,
                          userAvatars: viewModel.userAvatars,
                          currentUsername: viewModel.username,
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
                        allUsernames: allUsernames.toList(),
                        onAttachmentSelected: (filePath) async {
                          final url = await viewModel.uploadAttachmentAndGetUrl(filePath);
                          if (url != null && url.isNotEmpty) {
                            final controller = viewModel.msgController;
                            final text = controller.text;
                            final selection = controller.selection;
                            final cursor = selection.baseOffset < 0 ? text.length : selection.baseOffset;
                            final filename = url.split('/').last;
                            final hyperlink = '[$filename]($url)';
                            final newText = text.replaceRange(cursor, cursor, hyperlink + ' ');
                            controller.value = controller.value.copyWith(
                              text: newText,
                              selection: TextSelection.collapsed(offset: cursor + hyperlink.length + 1),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),

                // --- Scrim (Dark Overlay) ---
                // This appears when a drawer is open to dim the main content
                // and provides a large tappable area to close the drawer.
                if (viewModel.showLeftDrawer || viewModel.showRightDrawer)
                  AnimatedOpacity(
                    opacity: 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: GestureDetector(
                      onTap: () {
                        if (viewModel.showLeftDrawer) viewModel.toggleLeftDrawer();
                        if (viewModel.showRightDrawer) viewModel.toggleRightDrawer();
                      },
                      child: Container(
                        color: Colors.black.withOpacity(0.5),
                      ),
                    ),
                  ),

                // --- Left Drawer (Animated) ---
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  left: viewModel.showLeftDrawer ? 0 : -leftDrawerWidth,
                  top: 0,
                  bottom: 0,
                  width: leftDrawerWidth,
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

                // --- Right Drawer (Animated) ---
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  right: viewModel.showRightDrawer ? 0 : -rightDrawerWidth,
                  top: 0,
                  bottom: 0,
                  width: rightDrawerWidth,
                  child: RightDrawer(
                    members: viewModel.members,
                    userAvatars: viewModel.userAvatars,
                    onCloseDrawer: viewModel.toggleRightDrawer,
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