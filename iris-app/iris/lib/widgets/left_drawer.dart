import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:provider/provider.dart'; // Import Provider
import 'package:collection/collection.dart'; // Import for `firstWhereOrNull`
import '../models/channel.dart';
import '../services/websocket_service.dart';
import '../models/user_status.dart';
import '../widgets/user_avatar.dart';
import '../screens/add_irc_server_screen.dart';
import '../models/irc_network.dart'; // Import IrcNetwork
import '../viewmodels/main_layout_viewmodel.dart'; // Import MainLayoutViewModel
import '../screens/edit_irc_server_screen.dart'; // New: Create this screen

class LeftDrawer extends StatelessWidget {
  final List<String> dms; // Now, these are "NetworkName/@dmUser"
  final Map<String, String> userAvatars;
  final Map<String, UserStatus> userStatuses;
  final List<String> joinedChannels; // Now, these are "NetworkName/#channelName"
  final List<String> unjoinedChannels; // Now, these are "NetworkName/#channelName"
  final String selectedConversationTarget; // Now, this is "NetworkName/channelName"
  final ValueChanged<String> onChannelSelected;
  final ValueChanged<String> onUnjoinedChannelTap;
  final ValueChanged<String> onDmSelected;
  final Function(int networkId, String dmChannelName) onRemoveDm; // Updated signature
  final VoidCallback onirisTap;
  final bool loadingChannels;
  final String? error;
  final WebSocketStatus wsStatus;
  final bool showDrawer;
  final VoidCallback onCloseDrawer;
  final bool unjoinedExpanded;
  final VoidCallback onToggleUnjoined;
  final ValueChanged<String> onChannelPart;
  final bool Function(String channelName) hasUnreadMessages;
  final Message? Function(String channelName) getLastMessage;
  final String currentUsername;

  const LeftDrawer({
    super.key,
    required this.dms,
    required this.userAvatars,
    required this.userStatuses,
    required this.joinedChannels,
    required this.unjoinedChannels,
    required this.selectedConversationTarget,
    required this.onChannelPart,
    required this.onChannelSelected,
    required this.onUnjoinedChannelTap,
    required this.onDmSelected,
    required this.onRemoveDm,
    required this.onirisTap,
    required this.loadingChannels,
    this.error,
    required this.wsStatus,
    required this.showDrawer,
    required this.onCloseDrawer,
    required this.unjoinedExpanded,
    required this.onToggleUnjoined,
    required this.hasUnreadMessages,
    required this.getLastMessage,
    required this.currentUsername,
  });

  void _showNewDMDialog(BuildContext context, MainLayoutViewModel viewModel) {
    TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New Direct Message'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Enter username'),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Start'),
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Navigator.of(context).pop(controller.text);
                }
              },
            ),
          ],
        );
      },
    ).then((username) {
      if (username != null && username.isNotEmpty) {
        // You'll need to decide which network to create the DM on.
        // For simplicity, let's assume the first connected network.
        // Or, you could prompt the user to select a network for the DM.
        final firstConnectedNetwork = viewModel.chatState.ircNetworks.firstWhereOrNull((net) => net.isConnected);
        if (firstConnectedNetwork != null) {
          viewModel.startNewDM(firstConnectedNetwork.networkName, username); // Pass network name for DM
          onCloseDrawer();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No connected networks to start a DM.")),
          );
        }
      }
    });
  }

  void _showDmOptions(BuildContext context, String dmChannelIdentifier, MainLayoutViewModel viewModel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Remove DM', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  final parts = dmChannelIdentifier.split('/');
                  if (parts.length >= 2) {
                    final networkName = parts[0];
                    final dmName = parts[1]; // This is the @user part
                    final network = viewModel.chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase());
                    if (network != null) {
                      onRemoveDm(network.id, dmName); // Pass networkId and raw DM name
                      onCloseDrawer();
                    }
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showLeaveDialog(BuildContext context, String channelIdentifier, MainLayoutViewModel viewModel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (BuildContext context) {
        final channelName = channelIdentifier.split('/').last; // Get just the channel name
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Leave $channelName?',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              ListTile(
                leading: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text('Leave Channel', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  onChannelPart(channelIdentifier); // Pass full identifier
                  onCloseDrawer();
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showNetworkOptions(BuildContext context, IrcNetwork network, MainLayoutViewModel viewModel) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  network.networkName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
              if (network.isConnected)
                ListTile(
                  leading: const Icon(Icons.link_off, color: Colors.redAccent),
                  title: const Text('Disconnect', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    viewModel.disconnectIrcNetwork(network.id);
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.link, color: Colors.greenAccent),
                  title: const Text('Connect', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    viewModel.connectIrcNetwork(network.id);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.blueAccent),
                title: const Text('Edit Network', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EditIrcServerScreen(
                        network: network,
                        chatController: viewModel.chatController, // PASS CHATCONTROLLER
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete Network', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  showDialog(
                    context: context,
                    builder: (BuildContext dialogContext) {
                      return AlertDialog(
                        title: const Text('Delete Network?'),
                        content: Text(
                            'Are you sure you want to delete the network "${network.networkName}"? This cannot be undone.'),
                        actions: [
                          TextButton(
                            child: const Text('Cancel'),
                            onPressed: () => Navigator.pop(dialogContext),
                          ),
                          TextButton(
                            child: const Text('Delete', style: TextStyle(color: Colors.red)),
                            onPressed: () async {
                              Navigator.pop(dialogContext);
                              await viewModel.deleteIrcNetwork(network.id);
                            },
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.cancel, color: Colors.white),
                title: const Text('Cancel', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      },
    );
  }

  // Helper to get the currently selected network ID
  int _getSelectedNetworkId(MainLayoutViewModel viewModel) {
    if (viewModel.selectedConversationTarget.isEmpty) return -1;
    final parts = viewModel.selectedConversationTarget.split('/');
    if (parts.length < 2) return -1;
    final networkName = parts[0];
    return viewModel.chatState.ircNetworks.firstWhereOrNull((net) => net.networkName.toLowerCase() == networkName.toLowerCase())?.id ?? -1;
  }

  // New widget to display a server/network item
  Widget _buildServerListItem(
    BuildContext context,
    IrcNetwork network,
    MainLayoutViewModel viewModel,
    VoidCallback onCloseDrawer,
  ) {
    final isSelectedNetwork = viewModel.selectedConversationTarget.startsWith("${network.networkName}/");
    final backgroundColor = isSelectedNetwork ? const Color(0xFF5865F2) : Colors.transparent;
    final iconColor = isSelectedNetwork ? Colors.white : Colors.white70;

    // Define the border color for both selected and unselected states
    const unselectedBorderColor = Colors.white12; // A subtle grey for the border
    final selectedBorderColor = const Color(0xFF5865F2); // The accent color for selected
    final currentBorderColor = isSelectedNetwork ? selectedBorderColor : unselectedBorderColor;


    return Tooltip(
      message: network.networkName,
      child: GestureDetector(
        onTap: () {
          // If this network is already selected, select the main view.
          // Otherwise, select the first channel in this network.
          if (isSelectedNetwork) {
            viewModel.selectMainView();
          } else {
            viewModel.selectMainViewForNetwork(network.id);
          }
          onCloseDrawer(); // Close the drawer after selection
        },
        onLongPress: () => _showNetworkOptions(context, network, viewModel),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: CircleAvatar(
            radius: 28,
            backgroundColor: backgroundColor, // This sets the fill color on selection
            // We use a Container as the child to draw the border
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: currentBorderColor, width: 2), // The visible border
              ),
              child: Center(child: Text(network.networkName.isNotEmpty ? network.networkName[0].toUpperCase() : '?', style: TextStyle(color: iconColor, fontSize: 20, fontWeight: FontWeight.bold))),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = Provider.of<MainLayoutViewModel>(context);

    // Group channels by network
    final Map<IrcNetwork, List<String>> channelsByNetwork = {};
    for (final net in viewModel.chatState.ircNetworks) {
      channelsByNetwork[net] = [];
      for (final channelState in net.channels) {
        channelsByNetwork[net]?.add("${net.networkName}/${channelState.name}");
      }
    }

    final sortedNetworks = channelsByNetwork.keys.toList()
      ..sort((a, b) => a.networkName.toLowerCase().compareTo(b.networkName.toLowerCase()));

    final isDesktopLayout = kIsWeb; // Assuming desktop layout for web

    // --- Start of moved variable declarations for the main channel list ---
    final selectedNetworkId = _getSelectedNetworkId(viewModel);
    final currentNetwork = viewModel.chatState.ircNetworks.firstWhereOrNull((net) => net.id == selectedNetworkId);

    final List<String> joinedChannelsForSelectedNet;
    final List<String> unjoinedChannelsForSelectedNet;
    final List<String> dmsForSelectedNet;

    if (currentNetwork != null) {
      joinedChannelsForSelectedNet = currentNetwork.channels
          .where((c) => c.name.startsWith('#') && c.members.isNotEmpty)
          .map((c) => "${currentNetwork.networkName}/${c.name}")
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      unjoinedChannelsForSelectedNet = currentNetwork.channels
          .where((c) => c.name.startsWith('#') && c.members.isEmpty)
          .map((c) => "${currentNetwork.networkName}/${c.name}")
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      dmsForSelectedNet = currentNetwork.channels
          .where((c) => c.name.startsWith('@'))
          .map((c) => "${currentNetwork.networkName}/${c.name}")
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    } else {
      joinedChannelsForSelectedNet = [];
      unjoinedChannelsForSelectedNet = [];
      dmsForSelectedNet = [];
    }
    // --- End of moved variable declarations ---

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          // Server list column (left-most)
          Container(
            width: 80,
            color: const Color(0xFF232428),
            child: SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 20),
                  Tooltip(
                    message: "Channels",
                    child: GestureDetector(
                      onTap: onirisTap,
                      child: CircleAvatar(
                        radius: 28,
                        backgroundColor: viewModel.selectedConversationTarget.isEmpty ? const Color(0xFF5865F2) : Colors.transparent,
                        child: Icon(Icons.chat, color: viewModel.selectedConversationTarget.isEmpty ? Colors.white : Colors.white70, size: 28),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: Colors.white24, indent: 20, endIndent: 20),
                  // Add new server button
                  Tooltip(
                    message: "Add IRC Server",
                    child: GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AddIrcServerScreen(),
                          ),
                        );
                      },
                      child: const CircleAvatar(
                        radius: 28,
                        backgroundColor: Colors.green,
                        child: Icon(Icons.add, color: Colors.white, size: 28),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Divider(color: Colors.white24, indent: 20, endIndent: 20),

                  // Server List - now uses new _buildServerListItem
                  Expanded(
                    child: ListView.builder(
                      itemCount: sortedNetworks.length,
                      itemBuilder: (context, index) {
                        final network = sortedNetworks[index];
                        return _buildServerListItem(context, network, viewModel, onCloseDrawer);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Main channel/DM list column
          Expanded(
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text(
                      // Display selected network's name or "Channels"
                      currentNetwork != null
                          ? currentNetwork.networkName
                          : "Channels",
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8.0),
                      children: [
                        if (loadingChannels)
                          const Center(
                              child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          ))
                        else if (error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16),
                            child: Text(error!,
                                style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontSize: 13)),
                          )
                        else if (viewModel.selectedConversationTarget.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16.0),
                            child: Text(
                              "Select a network to see its channels and DMs.",
                              style: TextStyle(color: Colors.white70, fontStyle: FontStyle.italic),
                            ),
                          )
                        else ...[
                          // Joined Channels for the selected Network
                          if (joinedChannelsForSelectedNet.isNotEmpty)
                            ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                              leading: const Icon(Icons.tag, color: Colors.white70),
                              title: Text(
                                "Joined Channels",
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              iconColor: Colors.grey[400],
                              collapsedIconColor: Colors.grey[400],
                              initiallyExpanded: true,
                              children: joinedChannelsForSelectedNet.map((channelIdentifier) {
                                final channelName = channelIdentifier.split('/').last;
                                final isSelected = selectedConversationTarget.toLowerCase() == channelIdentifier.toLowerCase();
                                final lastMessage = getLastMessage(channelIdentifier);
                                final isUnread = hasUnreadMessages(channelIdentifier) &&
                                    (lastMessage != null && lastMessage.from.toLowerCase() != currentUsername.toLowerCase());
                                final String? subtitle = (isUnread && lastMessage != null)
                                    ? '${lastMessage.from}: ${lastMessage.content}'
                                    : null;

                                return ChannelListItem(
                                  name: channelName,
                                  isSelected: isSelected,
                                  isUnread: isUnread,
                                  subtitle: subtitle,
                                  onTap: () {
                                    onChannelSelected(channelIdentifier);
                                    onCloseDrawer();
                                  },
                                  onLongPress: () => _showLeaveDialog(context, channelIdentifier, viewModel),
                                );
                              }).toList(),
                            ),

                          // Unjoined Channels for the selected Network
                          if (unjoinedChannelsForSelectedNet.isNotEmpty)
                            ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                              leading: const Icon(Icons.add_box_outlined, color: Colors.white70),
                              title: Text(
                                "Other Channels",
                                style: TextStyle(
                                    color: Colors.grey[400],
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                              iconColor: Colors.grey[400],
                              collapsedIconColor: Colors.grey[400],
                              initiallyExpanded: unjoinedExpanded,
                              onExpansionChanged: (_) => onToggleUnjoined(),
                              children: unjoinedChannelsForSelectedNet.map((channelIdentifier) {
                                final channelName = channelIdentifier.split('/').last;
                                return ChannelListItem(
                                  name: channelName,
                                  isSelected: false,
                                  isUnread: false,
                                  onTap: () {
                                    onUnjoinedChannelTap(channelIdentifier);
                                    onCloseDrawer();
                                  },
                                );
                              }).toList(),
                            ),

                          // DMs for the selected Network
                          if (dmsForSelectedNet.isNotEmpty)
                            ExpansionTile(
                              tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                              leading: const Icon(Icons.person, color: Colors.white70),
                              title: Text(
                                "Direct Messages",
                                style: TextStyle(
                                    color: Colors.grey[400],
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12),
                              ),
                              iconColor: Colors.grey[400],
                              collapsedIconColor: Colors.grey[400],
                              initiallyExpanded: true,
                              children: dmsForSelectedNet.map((dmIdentifier) {
                                final dmName = dmIdentifier.split('/').last;
                                final isSelected = selectedConversationTarget.toLowerCase() == dmIdentifier.toLowerCase();
                                final lastMessage = getLastMessage(dmIdentifier);
                                final isUnread = hasUnreadMessages(dmIdentifier) && (lastMessage != null && lastMessage.from.toLowerCase() != currentUsername.toLowerCase());
                                final String? subtitle = (isUnread && lastMessage != null)
                                    ? '${lastMessage.from}: ${lastMessage.content}'
                                    : null;
                                return DMListItem(
                                  name: dmName,
                                  isSelected: isSelected,
                                  isUnread: isUnread,
                                  subtitle: subtitle,
                                  onTap: () {
                                    onDmSelected(dmIdentifier);
                                    onCloseDrawer();
                                  },
                                  onLongPress: () => _showDmOptions(context, dmIdentifier, viewModel),
                                  userAvatarUrl: userAvatars[dmName.substring(1)],
                                  userStatus: viewModel.chatState.userStatuses[dmName.substring(1)] ?? UserStatus.offline,
                                );
                              }).toList(),
                            ),
                           // Direct Message button - always available regardless of selected network
                           // but visually placed within the "channels" section
                            ListTile(
                              leading: const Icon(Icons.message, color: Colors.white70),
                              title: const Text('New Direct Message', style: TextStyle(color: Colors.white)),
                              onTap: () => _showNewDMDialog(context, viewModel),
                            ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Always show the close handle, both web and mobile!
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: const Center(
                child: Icon(
                  Icons.chevron_left,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Add these new list item widgets
class DMListItem extends StatelessWidget {
  final String name; // e.g., "@username"
  final bool isSelected;
  final bool isUnread;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? userAvatarUrl;
  final UserStatus userStatus;

  const DMListItem({
    Key? key,
    required this.name,
    required this.isSelected,
    required this.isUnread,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
    this.userAvatarUrl,
    required this.userStatus,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool isActive = isSelected || (isUnread && !isSelected);
    final String actualUsername = name.substring(1); // Remove '@'

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Material(
        color: isSelected ? const Color(0xFF5865F2).withOpacity(0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(5),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 4,
                height: isUnread && !isSelected ? (subtitle != null ? 36 : 24) : 0,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(4),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
              ),
              UserAvatar(
                username: actualUsername,
                avatarUrl: userAvatarUrl,
                status: userStatus,
                radius: 14,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name, // Display as @username
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white70,
                          fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                          fontSize: 16,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChannelListItem extends StatelessWidget {
  final String name; // e.g., "#general"
  final bool isSelected;
  final bool isUnread;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ChannelListItem({
    Key? key,
    required this.name,
    required this.isSelected,
    required this.isUnread,
    this.subtitle,
    required this.onTap,
    this.onLongPress,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bool isActive = isSelected || (isUnread && !isSelected);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.0),
      child: Material(
        color: isSelected ? const Color(0xFF5865F2).withOpacity(0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(5),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 4,
                height: isUnread && !isSelected ? (subtitle != null ? 36 : 24) : 0,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(4),
                    bottomLeft: Radius.circular(4),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white70,
                          fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                          fontSize: 16,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}