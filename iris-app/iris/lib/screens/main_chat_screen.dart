import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb and defaultTargetPlatform
import 'package:provider/provider.dart';

import '../viewmodels/main_layout_viewmodel.dart';
import '../widgets/left_drawer.dart';
import '../widgets/right_drawer.dart';
import '../widgets/message_list.dart';
import '../widgets/message_input.dart';
import '../screens/profile_screen.dart';
import '../models/encryption_session.dart';
import '../widgets/channel_topic.dart';
import '../commands/slash_command.dart'; // Import for SlashCommand type

class MainChatScreen extends StatefulWidget {
  const MainChatScreen({super.key});

  @override
  State<MainChatScreen> createState() => _MainChatScreenState();
}

class _MainChatScreenState extends State<MainChatScreen> {
  PageController? _pageController;

  @override
  void initState() {
    super.initState();
    // Initialize PageController only for Android
    if (defaultTargetPlatform == TargetPlatform.android) {
      _pageController = PageController(initialPage: 1);
    }
  }

  @override
  void dispose() {
    // Dispose PageController if it was created
    _pageController?.dispose();
    super.dispose();
  }

  void _showSafetyNumberDialog(
    BuildContext context,
    MainLayoutViewModel viewModel,
  ) {
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
    MainLayoutViewModel viewModel,
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
                    _showSafetyNumberDialog(context, viewModel);
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
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _buildAndroidLayout(context);
    } else {
      return _buildDesktopLayout(context);
    }
  }

  /// Builds the new PageView-based layout for Android.
  Widget _buildAndroidLayout(BuildContext context) {
    return Consumer<MainLayoutViewModel>(builder: (context, viewModel, child) {
      // Setup variables and callbacks for the Android layout
      final allUsernames = {
        ...viewModel.chatState.ircNetworks.expand((net) => net.channels).expand((ch) => ch.members.map((m) => m.nick)),
        ...viewModel.chatState.ircNetworks.expand((net) => net.channels).where((ch) => ch.name.startsWith('@')).map((ch) => ch.name.substring(1)),
        ...viewModel.currentChannelMessages.map((m) => m.from),
      };

      final isDm = viewModel.selectedConversationTarget.split('/').last.startsWith('@');
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

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (viewModel.shouldShowSafetyNumberDialog) {
          _showSafetyNumberDialog(context, viewModel);
          viewModel.didShowSafetyNumberDialog();
        }
      });

      // Auto-slide-back callbacks
      final slideToMain = () => _pageController?.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);

      final onChannelSelectedAndroid = (String id) {
        viewModel.onChannelSelected(id);
        slideToMain();
      };

      final onUnjoinedChannelTapAndroid = (String id) {
        viewModel.onUnjoinedChannelTap(id);
        slideToMain();
      };

      final onDmSelectedAndroid = (String id) {
        viewModel.onDmSelected(id);
        slideToMain();
      };

      final onirisTapAndroid = () {
        viewModel.selectMainView();
        slideToMain();
      };


      return PageView(
        controller: _pageController,
        children: [
          // Page 0: Left Panel (re-using LeftDrawer widget as a screen)
          LeftDrawer(
            dms: viewModel.dmChannelNames,
            userAvatars: viewModel.userAvatars,
            userStatuses: viewModel.chatState.userStatuses,
            joinedChannels: viewModel.joinedPublicChannelNames,
            unjoinedChannels: viewModel.unjoinedPublicChannelNames,
            selectedConversationTarget: viewModel.selectedConversationTarget,
            onChannelSelected: onChannelSelectedAndroid,
            onChannelPart: viewModel.partChannel,
            onUnjoinedChannelTap: onUnjoinedChannelTapAndroid,
            onDmSelected: onDmSelectedAndroid,
            onRemoveDm: (networkId, dmChannelName) => viewModel.removeDmChannel(networkId, dmChannelName),
            onirisTap: onirisTapAndroid,
            loadingChannels: viewModel.loadingChannels,
            error: viewModel.channelError,
            wsStatus: viewModel.wsStatus,
            showDrawer: true, // It's always "shown" in PageView
            onCloseDrawer: slideToMain,
            unjoinedExpanded: viewModel.unjoinedChannelsExpanded,
            onToggleUnjoined: viewModel.toggleUnjoinedChannelsExpanded,
            hasUnreadMessages: viewModel.hasUnreadMessages,
            getLastMessage: viewModel.getLastMessage,
            currentUsername: viewModel.username,
          ),

          // Page 1: Main Chat Screen
          Scaffold(
            backgroundColor: const Color(0xFF313338),
            appBar: AppBar(
              backgroundColor: const Color(0xFF232428),
              leading: IconButton(
                icon: const Icon(Icons.menu),
                tooltip: "Open Channels & Networks",
                onPressed: () => _pageController?.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
              ),
              title: Text(viewModel.selectedConversationTarget),
              actions: [
                if (isDm)
                  IconButton(
                    icon: Icon(lockIconData, color: lockIconColor),
                    tooltip: lockTooltip,
                    onPressed: () => _showEncryptionOptions(context, viewModel, encryptionStatus),
                  ),
                IconButton(
                  icon: const Icon(Icons.people),
                  tooltip: "Open Members List",
                  onPressed: () => _pageController?.animateToPage(2, duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
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
                        Navigator.push(context, MaterialPageRoute(builder: (context) => ProfileScreen(authToken: viewModel.token!)));
                      }
                    },
                    allUsernames: allUsernames.toList(),
                    availableCommands: viewModel.availableCommands,
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
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),

          // Page 2: Right Panel (re-using RightDrawer widget as a screen)
          RightDrawer(
            members: viewModel.members,
            userAvatars: viewModel.userAvatars,
            onCloseDrawer: slideToMain,
            channelName: viewModel.selectedChannelName,
            channelTopic: viewModel.selectedChannelTopic,
          ),
        ],
      );
    });
  }

  /// Builds the original layout for Web and Desktop platforms.
  Widget _buildDesktopLayout(BuildContext context) {
    const double leftDrawerWidth = 280;
    const double rightDrawerWidth = 240;

    return Consumer<MainLayoutViewModel>(
      builder: (context, viewModel, child) {
        final Set<String> allUsernames = {
          ...viewModel.chatState.ircNetworks.expand((net) => net.channels).expand((ch) => ch.members.map((m) => m.nick)),
          ...viewModel.chatState.ircNetworks.expand((net) => net.channels).where((ch) => ch.name.startsWith('@')).map((ch) => ch.name.substring(1)), // For DMs
          ...viewModel.currentChannelMessages.map((m) => m.from), // From current messages
        };

        final isDm = viewModel.selectedConversationTarget.split('/').last.startsWith('@');
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

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (viewModel.shouldShowSafetyNumberDialog) {
            _showSafetyNumberDialog(context, viewModel);
            viewModel.didShowSafetyNumberDialog(); // Reset the flag
          }
        });

        final isDesktopLayout =
            kIsWeb || defaultTargetPlatform == TargetPlatform.linux;

        return Scaffold(
          backgroundColor: const Color(0xFF313338),
          body: Row(
            children: [
              if (isDesktopLayout || viewModel.showLeftDrawer)
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
                      onRemoveDm: (networkId, dmChannelName) => viewModel.removeDmChannel(networkId, dmChannelName),
                      onirisTap: viewModel.selectMainView,
                      loadingChannels: viewModel.loadingChannels,
                      error: viewModel.channelError,
                      wsStatus: viewModel.wsStatus,
                      showDrawer: viewModel.showLeftDrawer,
                      onCloseDrawer: viewModel.toggleLeftDrawer,
                      unjoinedExpanded: viewModel.unjoinedChannelsExpanded,
                      onToggleUnjoined:
                          viewModel.toggleUnjoinedChannelsExpanded,
                      hasUnreadMessages: viewModel.hasUnreadMessages,
                      getLastMessage: viewModel.getLastMessage,
                      currentUsername: viewModel.username,
                    ),
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        if (isDesktopLayout) return;

                        final width = MediaQuery.of(context).size.width;
                        if (details.delta.dx > 5 &&
                            details.globalPosition.dx < 50) {
                          if (!viewModel.showLeftDrawer &&
                              !viewModel.showRightDrawer) {
                            viewModel.toggleLeftDrawer();
                          }
                        } else if (details.delta.dx < -5 &&
                            details.globalPosition.dx > width - 50) {
                          if (!viewModel.showLeftDrawer &&
                              !viewModel.showRightDrawer) {
                            viewModel.toggleRightDrawer();
                          }
                        } else if (viewModel.showLeftDrawer &&
                            details.delta.dx < -5) {
                          viewModel.toggleLeftDrawer();
                        } else if (viewModel.showRightDrawer &&
                            details.delta.dx > 5) {
                          viewModel.toggleRightDrawer();
                        }
                      },
                      child: SafeArea(
                        child: Column(
                          children: [
                            Container(
                              color: const Color(0xFF232428),
                              height: 56,
                              child: Row(
                                children: [
                                  if (!isDesktopLayout)
                                    Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.menu,
                                              color: Colors.white54),
                                          tooltip: "Open Channels Drawer",
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
                                                  color:
                                                      const Color(0xFF232428),
                                                  width: 1.5,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    child: Text(
                                      viewModel.selectedConversationTarget,
                                      style: const TextStyle(
                                          color: Colors.white, fontSize: 20),
                                    ),
                                  ),
                                  const Spacer(),
                                  if (isDm)
                                    IconButton(
                                      icon: Icon(lockIconData,
                                          color: lockIconColor),
                                      tooltip: lockTooltip,
                                      onPressed: () => _showEncryptionOptions(
                                          context,
                                          viewModel,
                                          encryptionStatus),
                                    ),
                                  if (!isDesktopLayout)
                                    IconButton(
                                      icon: const Icon(Icons.people,
                                          color: Colors.white70),
                                      tooltip: "Open Members Drawer",
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
                                      builder: (context) => ProfileScreen(
                                          authToken: viewModel.token!),
                                    ),
                                  );
                                }
                              },
                              allUsernames: allUsernames.toList(),
                              availableCommands: viewModel.availableCommands,
                              onAttachmentSelected: (filePath) async {
                                final url = await viewModel
                                    .uploadAttachmentAndGetUrl(filePath);
                                if (url != null && url.isNotEmpty) {
                                  final controller = viewModel.msgController;
                                  final text = controller.text;
                                  final selection = controller.selection;
                                  final cursor = selection.baseOffset < 0
                                      ? text.length
                                      : selection.baseOffset;
                                  final filename = url.split('/').last;
                                  final hyperlink = '[$filename]($url)';
                                  final newText = text.replaceRange(
                                      cursor, cursor, hyperlink + ' ');
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
                      ),
                    ),
                    if (!isDesktopLayout &&
                        (viewModel.showLeftDrawer ||
                            viewModel.showRightDrawer))
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () {
                            if (viewModel.showLeftDrawer) {
                              viewModel.toggleLeftDrawer();
                            }
                            if (viewModel.showRightDrawer) {
                              viewModel.toggleRightDrawer();
                            }
                          },
                          child: Container(
                            color: Colors.black.withOpacity(0.5),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (isDesktopLayout || viewModel.showRightDrawer)
                SizedBox(
                  width: rightDrawerWidth,
                  child: Drawer(
                    elevation: 0,
                    backgroundColor: Colors.transparent,
                    child: RightDrawer(
                      members: viewModel.members,
                      userAvatars: viewModel.userAvatars,
                      onCloseDrawer: viewModel.toggleRightDrawer,
                      channelName: viewModel.selectedChannelName,
                      channelTopic: viewModel.selectedChannelTopic,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}