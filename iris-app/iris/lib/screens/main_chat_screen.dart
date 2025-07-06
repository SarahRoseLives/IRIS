import 'package:flutter/foundation.dart'; // For kIsWeb and defaultTargetPlatform
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../commands/slash_command.dart'; // Import for SlashCommand type
import '../models/encryption_session.dart';
import '../screens/profile_screen.dart';
import '../viewmodels/main_layout_viewmodel.dart';
import '../widgets/channel_topic.dart';
import '../widgets/left_drawer.dart';
import '../widgets/message_input.dart';
import '../widgets/message_list.dart';
import '../widgets/right_drawer.dart';

class MainChatScreen extends StatelessWidget {
  const MainChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const double leftDrawerWidth = 280;
    const double rightDrawerWidth = 240;

    return Consumer<MainLayoutViewModel>(
      builder: (context, viewModel, child) {
        final isDesktopLayout = viewModel.isDesktopLayout;

        // The main chat view content is extracted into a reusable widget
        final mainChatView = _MainChatView(viewModel: viewModel);

        if (isDesktopLayout) {
          // --- WEB/DESKTOP LAYOUT (Existing Behavior) ---
          return Scaffold(
            backgroundColor: const Color(0xFF313338),
            body: Row(
              children: [
                // Left drawer is permanently visible on desktop
                SizedBox(
                  width: leftDrawerWidth,
                  child: Drawer(
                    elevation: 0,
                    backgroundColor: Colors.transparent,
                    child: LeftDrawer(
                      dms: viewModel.dmChannelNames,
                      userAvatars: viewModel.userAvatars,
                      userStatuses: viewModel.chatState.userStatuses,
                      joinedChannels: viewModel.joinedPublicChannelNames,
                      unjoinedChannels: viewModel.unjoinedPublicChannelNames,
                      selectedConversationTarget:
                          viewModel.selectedConversationTarget,
                      onChannelSelected: viewModel.onChannelSelected,
                      onChannelPart: viewModel.partChannel,
                      onUnjoinedChannelTap: viewModel.onUnjoinedChannelTap,
                      onDmSelected: viewModel.onDmSelected,
                      onRemoveDm: viewModel.removeDmChannel,
                      onIrisTap: viewModel.selectMainView,
                      loadingChannels: viewModel.loadingChannels,
                      error: viewModel.channelError,
                      wsStatus: viewModel.wsStatus,
                      onCloseDrawer: viewModel.closeSidePanels,
                      unjoinedExpanded: viewModel.unjoinedChannelsExpanded,
                      onToggleUnjoined:
                          viewModel.toggleUnjoinedChannelsExpanded,
                      hasUnreadMessages: viewModel.hasUnreadMessages,
                      getLastMessage: viewModel.getLastMessage,
                      currentUsername: viewModel.username,
                      isDrawer: true, // Render with web drawer UI
                    ),
                  ),
                ),
                // Main content area
                Expanded(child: mainChatView),
                // Right drawer is permanently visible on desktop
                SizedBox(
                  width: rightDrawerWidth,
                  child: Drawer(
                    elevation: 0,
                    backgroundColor: Colors.transparent,
                    child: RightDrawer(
                      members: viewModel.members,
                      userAvatars: viewModel.userAvatars,
                      onCloseDrawer: viewModel.closeSidePanels,
                      isDrawer: true, // Render with web drawer UI
                    ),
                  ),
                ),
              ],
            ),
          );
        } else {
          // --- ANDROID/MOBILE LAYOUT (New Sliding Screens) ---
          return Scaffold(
            backgroundColor: const Color(0xFF313338),
            body: PageView(
              controller: viewModel.pageController,
              children: [
                // Page 0: Left Panel Screen
                LeftDrawer(
                  dms: viewModel.dmChannelNames,
                  userAvatars: viewModel.userAvatars,
                  userStatuses: viewModel.chatState.userStatuses,
                  joinedChannels: viewModel.joinedPublicChannelNames,
                  unjoinedChannels: viewModel.unjoinedPublicChannelNames,
                  selectedConversationTarget:
                      viewModel.selectedConversationTarget,
                  onChannelSelected: viewModel.onChannelSelected,
                  onChannelPart: viewModel.partChannel,
                  onUnjoinedChannelTap: viewModel.onUnjoinedChannelTap,
                  onDmSelected: viewModel.onDmSelected,
                  onRemoveDm: viewModel.removeDmChannel,
                  onIrisTap: viewModel.selectMainView,
                  loadingChannels: viewModel.loadingChannels,
                  error: viewModel.channelError,
                  wsStatus: viewModel.wsStatus,
                  onCloseDrawer: viewModel.closeSidePanels,
                  unjoinedExpanded: viewModel.unjoinedChannelsExpanded,
                  onToggleUnjoined: viewModel.toggleUnjoinedChannelsExpanded,
                  hasUnreadMessages: viewModel.hasUnreadMessages,
                  getLastMessage: viewModel.getLastMessage,
                  currentUsername: viewModel.username,
                  isDrawer: false, // Render as a full page
                ),
                // Page 1: Main Chat Screen
                mainChatView,
                // Page 2: Right Panel Screen
                RightDrawer(
                  members: viewModel.members,
                  userAvatars: viewModel.userAvatars,
                  onCloseDrawer: viewModel.closeSidePanels,
                  isDrawer: false, // Render as a full page
                ),
              ],
            ),
          );
        }
      },
    );
  }
}

/// This private widget contains the reusable UI for the central chat view.
class _MainChatView extends StatelessWidget {
  final MainLayoutViewModel viewModel;

  const _MainChatView({required this.viewModel});

  void _showSafetyNumberDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return FutureBuilder<String?>(
          future: viewModel.getSafetyNumber(),
          builder: (context, snapshot) {
            Widget content;
            if (snapshot.connectionState == ConnectionState.waiting) {
              content = const Center(child: CircularProgressIndicator());
            } else if (snapshot.hasError || snapshot.data == null) {
              content = const Text(
                  "Could not generate Safety Number. The session may not be secure.");
            } else {
              content = RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontSize: 16),
                  children: [
                    const TextSpan(
                      text:
                          "To verify this connection is secure, compare this Safety Number with the other user through a separate channel (e.g., a phone call).\n\nIf they match, your connection is secure and private.\n\n",
                    ),
                    TextSpan(
                      text: snapshot.data!,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                        fontFamily: 'monospace',
                        color: Colors.lightGreenAccent,
                      ),
                    ),
                  ],
                ),
              );
            }
            return AlertDialog(
              title: const Text("Verify Safety Number"),
              content: content,
              actions: [
                TextButton(
                  child: const Text("OK"),
                  onPressed: () => Navigator.of(context).pop(),
                )
              ],
            );
          },
        );
      },
    );
  }

  void _showEncryptionOptions(
    BuildContext context,
    EncryptionStatus status,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status == EncryptionStatus.active) ...[
                ListTile(
                  leading: const Icon(Icons.verified_user, color: Colors.green),
                  title: const Text('Verify Safety Number',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _showSafetyNumberDialog(context);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lock_open, color: Colors.red),
                  title: const Text('End Encryption',
                      style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(context);
                    viewModel.toggleEncryption();
                  },
                ),
              ] else if (status == EncryptionStatus.none) ...[
                ListTile(
                  leading: const Icon(Icons.lock, color: Colors.green),
                  title: const Text('Start Encrypted Session',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    viewModel.toggleEncryption();
                  },
                ),
              ] else if (status == EncryptionStatus.pending) ...[
                const ListTile(
                  leading: Icon(Icons.lock_clock, color: Colors.amber),
                  title: Text('Encryption Pending...',
                      style: TextStyle(color: Colors.amber)),
                ),
              ] else if (status == EncryptionStatus.error) ...[
                ListTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: const Text('Reset Encryption',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    viewModel.toggleEncryption();
                  },
                ),
              ],
              const Divider(height: 1, color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title:
                    const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final Set<String> allUsernames = {
      ...viewModel.members.map((m) => m.nick),
      ...viewModel.currentChannelMessages.map((m) => m.from),
    };

    final isDm = viewModel.selectedConversationTarget.startsWith('@');
    final encryptionStatus = viewModel.currentEncryptionStatus;

    IconData lockIconData;
    Color lockIconColor;
    String lockTooltip;

    switch (encryptionStatus) {
      case EncryptionStatus.active:
        lockIconData = Icons.lock;
        lockIconColor = Colors.greenAccent;
        lockTooltip = "Encrypted session is active. Click to end.";
        break;
      case EncryptionStatus.pending:
        lockIconData = Icons.lock_clock;
        lockIconColor = Colors.amber;
        lockTooltip = "Encryption request is pending...";
        break;
      case EncryptionStatus.error:
        lockIconData = Icons.error;
        lockIconColor = Colors.redAccent;
        lockTooltip = "Encryption error. Click to reset.";
        break;
      case EncryptionStatus.none:
      default:
        lockIconData = Icons.lock_open;
        lockIconColor = Colors.white70;
        lockTooltip = "Session is not encrypted. Click to start.";
        break;
    }

    // Listen for when a session becomes active to show the dialog
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (viewModel.shouldShowSafetyNumberDialog) {
        _showSafetyNumberDialog(context);
        viewModel.didShowSafetyNumberDialog(); // Reset the flag
      }
    });

    return SafeArea(
      child: Column(
        children: [
          Container(
            color: const Color(0xFF232428),
            height: 56,
            child: Row(
              children: [
                if (!viewModel.isDesktopLayout)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.menu, color: Colors.white54),
                        tooltip: "Open Channels & DMs",
                        onPressed: viewModel.toggleLeftDrawer,
                      ),
                      if (viewModel.hasUnreadDms)
                        Positioned(
                          bottom: 12,
                          right: 12,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF232428),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    viewModel.selectedConversationTarget,
                    style: const TextStyle(color: Colors.white, fontSize: 20),
                  ),
                ),
                const Spacer(),
                if (isDm)
                  IconButton(
                    icon: Icon(lockIconData, color: lockIconColor),
                    tooltip: lockTooltip,
                    onPressed: () =>
                        _showEncryptionOptions(context, encryptionStatus),
                  ),
                if (!viewModel.isDesktopLayout)
                  IconButton(
                    icon: const Icon(Icons.people, color: Colors.white70),
                    tooltip: "Open Members List",
                    onPressed: viewModel.toggleRightDrawer,
                  ),
              ],
            ),
          ),
          if (!isDm) const ChannelTopic(),
          Expanded(
            child: MessageList(
              messages: viewModel.currentChannelMessages,
              scrollController: viewModel.scrollController,
              userAvatars: viewModel.userAvatars,
              currentUsername: viewModel.username,
              encryptionStatus: encryptionStatus,
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
                    builder: (context) =>
                        ProfileScreen(authToken: viewModel.token!),
                  ),
                );
              }
            },
            allUsernames: allUsernames.toList(),
            availableCommands: viewModel.availableCommands,
            onAttachmentSelected: (filePath) async {
              final url =
                  await viewModel.uploadAttachmentAndGetUrl(filePath);
              if (url != null && url.isNotEmpty) {
                final controller = viewModel.msgController;
                final text = controller.text;
                final selection = controller.selection;
                final cursor =
                    selection.baseOffset < 0 ? text.length : selection.baseOffset;
                final filename = url.split('/').last;
                final hyperlink = '[$filename]($url)';
                final newText =
                    text.replaceRange(cursor, cursor, '$hyperlink ');
                controller.value = controller.value.copyWith(
                  text: newText,
                  selection: TextSelection.collapsed(
                      offset: cursor + hyperlink.length + 1),
                );
              }
              return null;
            },
          ),
        ],
      ),
    );
  }
}