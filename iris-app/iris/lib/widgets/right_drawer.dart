import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:provider/provider.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import 'user_avatar.dart';
import '../utils/irc_helpers.dart';
import '../viewmodels/main_layout_viewmodel.dart';

class RightDrawer extends StatelessWidget {
  final List<ChannelMember> members;
  final Map<String, String> userAvatars;
  final VoidCallback onCloseDrawer;
  final String channelName;
  final String channelTopic;

  const RightDrawer({
    super.key,
    required this.members,
    required this.userAvatars,
    required this.onCloseDrawer,
    required this.channelName,
    required this.channelTopic,
  });

  // Grouping logic for IRC roles
  static const _roleOrder = [
    '~', // Owner
    '&', // Admin
    '@', // Op
    '%', // Halfop
    '+', // Voice
    '', // Regular
  ];

  static const _roleLabels = {
    '~': "Owners",
    '&': "Admins",
    '@': "Operators",
    '%': "Half-ops",
    '+': "Voiced",
    '': "Members",
  };

  // Colors for role nicks
  static const _roleNickColors = {
    '~': Color(0xFFB388FF), // purple
    '&': Color(0xFF00E676), // green
    '@': Color(0xFFFFD600), // yellow
    '%': Color(0xFF29B6F6), // blue
    '+': Color(0xFFFF8A65), // orange
    '': Colors.white,
  };

  // Used to group members by their IRC role prefix.
  Map<String, List<ChannelMember>> _groupByRole(List<ChannelMember> users) {
    final map = <String, List<ChannelMember>>{};
    for (final member in users) {
      final prefix = member.prefix;
      map.putIfAbsent(prefix, () => []).add(member);
    }
    return map;
  }

  // Member options bottom sheet with working DM
  void _showMemberOptions(BuildContext context, String username) {
    final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);

    // Get the current network name from the selected conversation target
    final currentConversationTarget = viewModel.selectedConversationTarget;
    final parts = currentConversationTarget.split('/');
    String networkName = '';
    if (parts.isNotEmpty) {
      networkName = parts[0];
    }

    if (networkName.isEmpty || networkName == 'No channels') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Cannot start DM: No active network selected.")),
      );
      Navigator.pop(context);
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF313338),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.message, color: Colors.white),
                title: const Text('Send Direct Message', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  viewModel.startNewDM(networkName, username);
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

  Widget _buildSectionTitle(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 0, 6),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white60,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
          fontSize: 15,
        ),
      ),
    );
  }

  // Each member row, styled as in screenshot
  Widget _buildMemberTile(BuildContext context, ChannelMember member, {bool isOwner = false, bool isOperator = false}) {
    final avatarUrl = userAvatars[member.nick];
    final status = member.isAway ? UserStatus.away : UserStatus.online;
    final roleColor = _roleNickColors[member.prefix] ?? Colors.white;
    final displayName = member.nick;
    final nickTextStyle = TextStyle(
      color: roleColor,
      fontWeight: FontWeight.w700,
      fontSize: 17,
      letterSpacing: 0.1,
    );
    final roleBadge = isOwner
        ? Icon(Icons.stars, color: Color(0xFFB388FF), size: 20)
        : isOperator
            ? Icon(Icons.shield, color: Color(0xFFFFD600), size: 20)
            : null;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onLongPress: () => _showMemberOptions(context, member.nick),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF232428),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ListTile(
          leading: UserAvatar(
            username: member.nick,
            avatarUrl: avatarUrl,
            status: status,
            radius: 24,
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  style: nickTextStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (roleBadge != null) ...[
                const SizedBox(width: 6),
                roleBadge,
              ],
            ],
          ),
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  // Grouped member sections
  List<Widget> _buildMemberSections(BuildContext context, Map<String, List<ChannelMember>> groups) {
    final widgets = <Widget>[];
    for (final prefix in _roleOrder) {
      final group = groups[prefix];
      if (group != null && group.isNotEmpty) {
        widgets.add(_buildSectionTitle(_roleLabels[prefix]!));
        group.sort((a, b) => a.nick.toLowerCase().compareTo(b.nick.toLowerCase()));
        widgets.addAll(group.map((member) {
          final isOwner = prefix == '~';
          final isOperator = prefix == '@';
          return _buildMemberTile(context, member, isOwner: isOwner, isOperator: isOperator);
        }));
      }
    }
    return widgets;
  }

  // Placeholder action buttons row
  Widget _buildButtonsRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildCircleButton(icon: Icons.search),
          const SizedBox(width: 22),
          _buildCircleButton(icon: Icons.forum),
          const SizedBox(width: 22),
          _buildCircleButton(icon: Icons.settings),
        ],
      ),
    );
  }

  Widget _buildCircleButton({required IconData icon}) {
    return Material(
      color: const Color(0xFF232428),
      shape: const CircleBorder(),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: () {}, // TODO: implement action
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Split members into online and away for each role
    final onlineMembers = members.where((m) => !m.isAway).toList();
    final awayMembers = members.where((m) => m.isAway).toList();

    final onlineGroups = _groupByRole(onlineMembers);
    final awayGroups = _groupByRole(awayMembers);

    return Material(
      color: Colors.transparent,
      child: Row(
        children: [
          // Always show the close handle, both web and mobile!
          GestureDetector(
            onTap: onCloseDrawer,
            child: Container(
              width: 20,
              height: double.infinity,
              color: const Color(0xFF232428),
              child: const Center(
                child: Icon(
                  Icons.chevron_right,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF232428), Color(0xFF2B2D31)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    // Channel name and topic centered at the top
                    Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 6),
                      child: Column(
                        children: [
                          Text(
                            channelName.startsWith('#') ? channelName : '#$channelName',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 28,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            channelTopic,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w400,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildButtonsRow(),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.02),
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(24),
                            topRight: Radius.circular(24),
                          ),
                        ),
                        child: members.isEmpty
                            ? const Center(
                                child: Text(
                                  "No members",
                                  style: TextStyle(color: Colors.white54),
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.only(top: 8, bottom: 16),
                                children: [
                                  ..._buildMemberSections(context, onlineGroups),
                                  if (awayMembers.isNotEmpty) ...[
                                    _buildSectionTitle("Away"),
                                    ..._buildMemberSections(context, awayGroups),
                                  ]
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}