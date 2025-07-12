import 'package:flutter/material.dart';
import 'dart:async';
import 'package:get_it/get_it.dart';
import 'package:flutter/foundation.dart'; // Needed for kIsWeb
import 'package:collection/collection.dart'; // Import for `firstWhereOrNull`

import '../main.dart'; // Provides AuthManager
import '../services/api_service.dart'; // Provides SessionExpiredException

import '../services/websocket_service.dart';
import '../services/notification_service_platform.dart';
import '../controllers/chat_state.dart'; // This import is correct
import '../controllers/chat_controller.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/encryption_session.dart';
import '../commands/slash_command.dart'; // Import for commands
import '../models/irc_role.dart';
import '../models/irc_network.dart'; // Import IrcNetwork

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver {
  // State and Controller
  late final ChatState chatState;
  late final ChatController _chatController; // Assign directly

  // Dependencies
  final String username;
  final String? token;

  // UI-specific State
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;
  bool _unjoinedChannelsExpanded = false;
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription? _wsStatusSub;
  StreamSubscription? _errorSub;

  final Set<String> _blockedUsers = {};
  final Set<String> _hiddenMessageIds = {};

  bool _userScrolledUp = false;

  Set<String> get blockedUsers => _blockedUsers;
  Set<String> get hiddenMessageIds => _hiddenMessageIds;

  void blockUser(String username) {
    _blockedUsers.add(username.toLowerCase());
    notifyListeners();
  }

  void unblockUser(String username) {
    _blockedUsers.remove(username.toLowerCase());
    notifyListeners();
  }

  void hideMessage(String messageId) {
    _hiddenMessageIds.add(messageId);
    notifyListeners();
  }

  void unhideMessage(String messageId) {
    _hiddenMessageIds.remove(messageId);
    notifyListeners();
  }

  // Modified constructor to accept ChatController
  MainLayoutViewModel({required this.username, this.token, required ChatController chatController}) {
    if (token == null) {
      print("[ViewModel] Error: Token is null. Cannot initialize ViewModel properly.");
      _loadingChannels = false;
      _channelError = "Authentication token not found.";
      return;
    }

    _chatController = chatController; // Assign the passed instance
    chatState = GetIt.instance<ChatState>(); // ChatState is still a singleton

    // Set the callback for NotificationService to suppress notifications for active DM
    NotificationService.getCurrentDMChannel = () {
      final target = chatState.selectedConversationTarget;
      // Check if it's a DM and extract the user's nickname (e.g., from "NetworkName/@user" take "@user")
      if (target.contains('/') && target.split('/').last.startsWith('@')) {
        return target.split('/').last;
      }
      return null;
    };

    _scrollController.addListener(_onScroll);

    _initialize();
  }

  // Expose chatController for direct access in UI where appropriate (e.g., safety number dialog)
  ChatController get chatController => _chatController;

  // --- GETTERS ---
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  WebSocketStatus get wsStatus => _wsStatus;
  bool get unjoinedChannelsExpanded => _unjoinedChannelsExpanded;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;

  // Adjusted to use `selectedConversationIdentifier` from chatState
  List<Message> get currentChannelMessages {
    final selectedIdentifier = chatState.selectedConversationTarget;
    if (selectedIdentifier.isEmpty) return [];
    // Use new flexible getMessagesForChannel API with single string argument
    return chatState.getMessagesForChannel(selectedIdentifier);
  }

  String get selectedConversationTarget => chatState.selectedConversationTarget;
  List<ChannelMember> get members => chatState.membersForSelectedChannel;
  Map<String, String> get userAvatars => chatState.userAvatars;
  Map<String, String> get userPronouns => chatState.userPronouns;
  List<String> get joinedPublicChannelNames => chatState.joinedPublicChannelNames;
  List<String> get unjoinedPublicChannelNames => chatState.unjoinedPublicChannelNames;
  List<String> get dmChannelNames => chatState.dmChannelNames;
  EncryptionStatus get currentEncryptionStatus =>
      chatState.getEncryptionStatus(selectedConversationTarget);

  // Directly use the flag from ChatController
  bool get shouldShowSafetyNumberDialog => _chatController.shouldShowSafetyNumberDialogAfterStatusChange;
  void didShowSafetyNumberDialog() => _chatController.didShowSafetyNumberDialog(); // Proxy to ChatController

  bool hasUnreadMessages(String channelIdentifier) =>
      chatState.hasUnreadMessages(channelIdentifier);
  Message? getLastMessage(String channelIdentifier) =>
      chatState.getLastMessage(channelIdentifier);

  List<SlashCommand> get availableCommands {
    final IrcRole userRole =
        _chatController.getCurrentUserRoleInChannel(selectedConversationTarget);
    return _chatController.getAvailableCommandsForRole(userRole);
  }

  bool get hasUnreadDms {
    for (final dmName in dmChannelNames) {
      if (hasUnreadMessages(dmName)) {
        final lastMessage = getLastMessage(dmName);
        // Only consider it an unread DM if the last message is not from the current user
        if (lastMessage != null && lastMessage.from.toLowerCase() != username.toLowerCase()) {
          return true;
        }
      }
    }
    return false;
  }

  /// NEW: Get the current selected channel name (for passing to RightDrawer)
  String get selectedChannelName {
    final parts = chatState.selectedConversationTarget.split('/');
    if (parts.length < 2) return '';
    return parts.skip(1).join('/');
  }

  /// NEW: Get the current selected channel topic (for passing to RightDrawer)
  String get selectedChannelTopic {
    final parts = chatState.selectedConversationTarget.split('/');
    if (parts.length < 2) return '';
    final networkName = parts[0];
    final channelName = parts.skip(1).join('/');

    final network = chatState.ircNetworks.firstWhereOrNull(
      (net) => net.networkName.toLowerCase() == networkName.toLowerCase(),
    );

    if (network == null) return '';
    final channel = network.channels.firstWhereOrNull(
      (ch) => ch.name.toLowerCase() == channelName.toLowerCase(),
    );
    return channel?.topic ?? '';
  }

  void _initialize() async {
    WidgetsBinding.instance.addObserver(this);
    chatState.addListener(_onChatStateChanged);
    _wsStatusSub = _chatController.wsStatusStream.listen(_onWsStatusChanged);
    _errorSub = _chatController.errorStream.listen(_onErrorChanged);

    _loadingChannels = true;
    notifyListeners();

    try {
      // ChatController.initialize() in AuthWrapper already fetches networks and history.
      // So here, we just need to react to the state it populates.
      // Load avatars for all users currently in state
      _loadAvatarsForExistingUsers();

      // If no conversation is selected after initial state load, select one.
      if (chatState.selectedConversationTarget.isEmpty) {
        selectMainView();
      }

    } on SessionExpiredException {
      AuthManager.forceLogout(showExpiredMessage: true);
    } catch (e) {
      _channelError = "Failed to load conversations: $e";
      print("[ViewModel] Initial load error: $e");
    } finally {
      _loadingChannels = false;
      notifyListeners();
    }
  }

  void _loadAvatarsForExistingUsers() {
    final allNicks = <String>{};
    // From IRC networks and channels
    for (final network in chatState.ircNetworks) {
      for (final channel in network.channels) {
        for (final member in channel.members) {
          allNicks.add(member.nick);
        }
        if (channel.name.startsWith('@')) { // For DMs in channel list (like @user)
          allNicks.add(channel.name.substring(1));
        }
      }
    }
    // From messages already loaded (e.g., historical DMs that might not have a channel member entry)
    for (final messagesList in chatState.channels.map((c) => chatState.getMessagesForChannel("${chatState.getNetworkNameForChannel(c.networkId)}/${c.name}"))) {
      for (final msg in messagesList) {
        allNicks.add(msg.from);
      }
    }
    // Load avatars for collected nicks
    for (final nick in allNicks) {
      _chatController.loadAvatarForUser(nick);
    }
  }

  void _onChatStateChanged() {
    // Only trigger safety number dialog logic if the encryption status actually changes to active
    // and the flag in ChatController is set.
    if (_chatController.shouldShowSafetyNumberDialogAfterStatusChange) {
      // The `shouldShowSafetyNumberDialog` getter will now reflect this from ChatController
      // and MainChatScreen will react via its WidgetsBinding.instance.addPostFrameCallback.
    }

    // Scroll to top automatically only if user is already at the bottom or it's a new channel selection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToTopIfAtBottom();
    });

    notifyListeners();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Check if user is scrolled within 50 pixels of the bottom
    final atBottom = position.pixels <= position.minScrollExtent + 50.0;
    if (atBottom != !_userScrolledUp) { // If atBottom true, then _userScrolledUp should be false
      _userScrolledUp = !atBottom;
    }
  }

  void _onWsStatusChanged(WebSocketStatus status) {
    if (status == WebSocketStatus.connected) {
      _loadingChannels = false;
      _channelError = null;
      // When WS connects, it should trigger initial state or network updates.
      // We can also process pending notifications here, as the chat state is now available.
      _chatController.processPendingBackgroundMessages(); // Process any stored FCM DMs
      _chatController.handlePendingNotification(); // FIXED: now calls the public method
    } else {
      _loadingChannels = status == WebSocketStatus.connecting;
    }
    _wsStatus = status;
    notifyListeners();
  }

  void _onErrorChanged(String? error) {
    _channelError = error;
    _loadingChannels = false;
    notifyListeners();
  }

  void toggleEncryption() {
    _chatController.initiateOrEndEncryption();
  }

  Future<String?> getSafetyNumber() {
    return _chatController.getSafetyNumberForTarget();
  }

  void toggleLeftDrawer() {
    if (kIsWeb) {
      _showLeftDrawer = !_showLeftDrawer;
    } else {
      _showLeftDrawer = !_showLeftDrawer;
      if (_showLeftDrawer) _showRightDrawer = false; // Close right if opening left on mobile
    }
    notifyListeners();
  }

  void toggleRightDrawer() {
    if (kIsWeb) {
      _showRightDrawer = !_showRightDrawer;
    } else {
      _showRightDrawer = !_showRightDrawer;
      if (_showRightDrawer) _showLeftDrawer = false; // Close left if opening right on mobile
    }
    notifyListeners();
  }

  void toggleUnjoinedChannelsExpanded() {
    _unjoinedChannelsExpanded = !_unjoinedChannelsExpanded;
    notifyListeners();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.minScrollExtent, // Scroll to the very bottom (or top if reversed)
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _scrollToTopIfAtBottom() {
    // Only scroll if the user hasn't manually scrolled up
    if (_scrollController.hasClients && !_userScrolledUp) {
      _scrollToTop();
    }
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text;
    if (text.trim().isEmpty) return;
    _msgController.clear();
    await _chatController.handleSendMessage(text);
    _userScrolledUp = false; // Reset scroll state when sending a message
    _scrollToTop();
  }

  Future<void> setMyPronouns(String pronouns) async {
    await _chatController.setMyPronouns(pronouns);
  }

  void onChannelSelected(String channelIdentifier) {
    chatState.selectConversation(channelIdentifier);
    _userScrolledUp = false; // Reset scroll state on channel change
    _scrollToTop();
    // Close drawers on mobile after selecting a channel
    if (!kIsWeb && (showLeftDrawer || showRightDrawer)) {
      toggleLeftDrawer(); // Or toggleRightDrawer(), depending on which is open
    }
  }

  void onUnjoinedChannelTap(String channelIdentifier) =>
      _chatController.joinChannel(channelIdentifier);

  void onDmSelected(String dmChannelIdentifier) => onChannelSelected(dmChannelIdentifier);

  void partChannel(String channelIdentifier) =>
      _chatController.partChannel(channelIdentifier);

  // New method to select the main view for a given network
  void selectMainViewForNetwork(int networkId) {
    final network = chatState.ircNetworks.firstWhereOrNull((net) => net.id == networkId);
    if (network == null) {
      chatState.addSystemMessage(0, "System", "Error: Network not found.");
      return;
    }

    // Prioritize selecting a joined channel within this network
    final firstJoinedChannelInNetwork = network.channels.firstWhereOrNull(
      (c) => c.name.startsWith('#') && c.members.isNotEmpty,
    );

    if (firstJoinedChannelInNetwork != null) {
      onChannelSelected("${network.networkName}/${firstJoinedChannelInNetwork.name}");
    } else if (network.channels.isNotEmpty) {
      // If no joined channels, but there are other channels (e.g., DMs or unjoined), select the first one
      onChannelSelected("${network.networkName}/${network.channels.first.name}");
    } else {
      // If no channels at all, fall back to a system message for that network
      chatState.addSystemMessage(network.id, network.networkName, "No channels found for this network. Join one or start a DM.");
    }
  }

  // Updated to prioritize joined channels, then DMs, then just display a system message.
  void selectMainView() {
    // Attempt to select the first joined channel
    final firstJoined = chatState.channels.firstWhereOrNull(
        (c) => c.name.startsWith('#') && c.members.isNotEmpty && chatState.getNetworkNameForChannel(c.networkId) != 'Unknown Network');
    if (firstJoined != null) {
      onChannelSelected("${chatState.getNetworkNameForChannel(firstJoined.networkId)}/${firstJoined.name}");
      return;
    }

    // If no joined channels, attempt to select the first DM
    final firstDm = chatState.channels.firstWhereOrNull(
        (c) => c.name.startsWith('@') && chatState.getNetworkNameForChannel(c.networkId) != 'Unknown Network');
    if (firstDm != null) {
      onChannelSelected("${chatState.getNetworkNameForChannel(firstDm.networkId)}/${firstDm.name}");
      return;
    }

    // If still no selection, pick the first available channel of any type
    final firstAnyChannel = chatState.channels.firstWhereOrNull(
        (c) => chatState.getNetworkNameForChannel(c.networkId) != 'Unknown Network');
    if (firstAnyChannel != null) {
      onChannelSelected("${chatState.getNetworkNameForChannel(firstAnyChannel.networkId)}/${firstAnyChannel.name}");
      return;
    }

    // Fallback: If absolutely no channels, set to an empty string and show a message
    chatState.selectConversation(''); // Clear selection
    chatState.addSystemMessage(0, "System", "No channels or DMs to display. Add an IRC network to begin.");
    print("[MainLayoutViewModel] No channels or DMs found to select as main view.");
  }

  Future<String?> uploadAttachmentAndGetUrl(String filePath) async {
    return await _chatController.uploadAttachmentAndGetUrl(filePath);
  }

  void startNewDM(String networkName, String username) {
    final network = chatState.ircNetworks.firstWhereOrNull(
        (net) => net.networkName.toLowerCase() == networkName.toLowerCase());

    if (network == null) {
      chatState.addSystemMessage(0, "System", "Error: Network '$networkName' not found for new DM.");
      notifyListeners();
      return;
    }

    final String dmChannelName = '@${username.trim()}';
    final String channelIdentifier = "$networkName/$dmChannelName";

    final existingDm = chatState.channels.firstWhereOrNull(
                (c) => c.networkId == network.id && c.name.toLowerCase() == dmChannelName.toLowerCase());

    if (existingDm == null) {
      chatState.addOrUpdateChannel(network.id, Channel(
        networkId: network.id,
        name: dmChannelName,
        members: [], // DMs don't have members in the same way regular channels do
      ));
    }
    chatState.selectConversation(channelIdentifier);
    _userScrolledUp = false;
    _scrollToTop();
  }

  void removeDmMessage(int networkId, Message message) {
    chatState.removeDmMessage(networkId, message);
  }

  void removeDmChannel(int networkId, String dmChannelName) {
    final rawDmChannelName = dmChannelName.startsWith('@') ? dmChannelName : '@$dmChannelName';

    final currentlySelectedIdentifier = selectedConversationTarget;

    chatState.removeDmChannel(networkId, rawDmChannelName);

    // After removing, if the removed DM was the active conversation, try to select another one.
    final selectedNetwork = chatState.ircNetworks.firstWhereOrNull((net) => currentlySelectedIdentifier.startsWith("${net.networkName}/"));
    final selectedRawChannelName = currentlySelectedIdentifier.split('/').last;

    if (selectedNetwork != null && selectedNetwork.id == networkId && selectedRawChannelName.toLowerCase() == rawDmChannelName.toLowerCase()) {
      selectMainView();
    } else if (selectedNetwork == null && rawDmChannelName.toLowerCase() == currentlySelectedIdentifier.toLowerCase()){
      // This handles cases where selectedConversationTarget might just be the raw DM name without network prefix
      // due to some edge cases or initial state.
      selectMainView();
    }
    notifyListeners();
  }

  Future<void> updateChannelTopic(String newTopic) async {
    try {
      final channelIdentifier = selectedConversationTarget;
      final parts = channelIdentifier.split('/');
      if (parts.length < 2) {
        chatState.addSystemMessage(0, channelIdentifier, 'Invalid channel for topic update.');
        return;
      }
      final networkName = parts[0];
      final channelName = parts.skip(1).join('/');

      final network = chatState.ircNetworks.firstWhereOrNull(
        (net) => net.networkName.toLowerCase() == networkName.toLowerCase(),
      );

      if (network == null) {
        chatState.addSystemMessage(0, channelIdentifier, 'Network not found for topic update.');
        return;
      }

      if (channelName.startsWith('#')) {
        _chatController.sendRawWebSocketMessage({
          'type': 'topic_change',
          'payload': {
            'network_id': network.id,
            'channel': channelName,
            'topic': newTopic,
          },
        });
      } else {
        chatState.addSystemMessage(0, channelIdentifier, 'Topic can only be set for channels.');
      }
    } catch (e) {
      chatState.addSystemMessage(
        0, selectedConversationTarget,
        'Failed to send topic update request: ${e.toString()}',
      );
    }
  }

  Future<void> addIrcNetwork(IrcNetwork network) async {
    await _chatController.addIrcNetwork(network);
  }

  Future<void> updateIrcNetwork(IrcNetwork network) async {
    await _chatController.updateIrcNetwork(network);
  }

  Future<void> deleteIrcNetwork(int networkId) async {
    await _chatController.deleteIrcNetwork(networkId);
  }

  Future<void> connectIrcNetwork(int networkId) async {
    await _chatController.connectIrcNetwork(networkId);
  }

  Future<void> disconnectIrcNetwork(int networkId) async {
    await _chatController.disconnectIrcNetwork(networkId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chatState.removeListener(_onChatStateChanged);
    _wsStatusSub?.cancel();
    _errorSub?.cancel();

    _scrollController.removeListener(_onScroll);
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Public method to process and handle pending notification navigation.
  /// This wraps the ChatController's method (no longer private).
  Future<void> handlePendingNotification() async {
    await _chatController.handlePendingNotification();
  }
}