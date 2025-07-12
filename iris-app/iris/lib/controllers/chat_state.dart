import 'package:flutter/foundation.dart'; // Required for ChangeNotifier
import 'package:collection/collection.dart'; // For firstWhereOrNull

import '../models/channel.dart'; // This import now correctly brings in Message and Channel
import '../models/irc_network.dart';
import '../models/encryption_session.dart';
import '../models/user_status.dart';
import '../models/channel_member.dart'; // NEW: Added for ChannelMember type

enum ConversationType { channel, dm }

class ChatState extends ChangeNotifier {
  // Store channels grouped by network ID
  final Map<int, List<Channel>> _channels = {};
  // Store networks separately, as they contain general network config and connection status
  List<IrcNetwork> ircNetworks = [];
  // Messages are keyed by "networkId_channelname_lowercase"
  final Map<String, List<Message>> _messages = {};
  final Map<String, EncryptionStatus> _encryptionSessions = {};
  final Map<String, String> _userAvatars = {};
  final Map<String, String> _userPronouns = {};
  final Map<String, UserStatus> _userStatuses = {};
  // Unread status for full channel identifiers ("NetworkName/#channel" or "NetworkName/@user")
  final Map<String, bool> _unreadStatus = {};

  String _selectedConversationTarget = ''; // Stores "NetworkName/#channel" or "NetworkName/@user"

  // Using a numeric index is problematic if the list order changes or items are removed.
  // Instead, _selectedConversationTarget is the canonical source of truth for selection.
  // int _selectedChannelIndex = -1; // Removed as it's redundant/problematic

  List<Channel> get channels {
    return _channels.values.expand((list) => list).toList();
  }

  String get selectedConversationTarget => _selectedConversationTarget;

  // Derive selectedChannel directly from _selectedConversationTarget for reliability
  Channel? get selectedChannel {
    if (_selectedConversationTarget.isEmpty) return null;

    final parts = _selectedConversationTarget.split('/');
    if (parts.length < 2) return null; // Invalid format

    final networkName = parts[0];
    final channelName = parts.skip(1).join('/');

    final network = ircNetworks.firstWhereOrNull(
      (net) => net.networkName.toLowerCase() == networkName.toLowerCase(),
    );

    if (network == null) return null;

    return _channels[network.id]?.firstWhereOrNull(
      (c) => c.name.toLowerCase() == channelName.toLowerCase(),
    );
  }

  List<ChannelMember> get membersForSelectedChannel {
    final currentChannel = selectedChannel;
    return currentChannel?.members ?? [];
  }

  Map<String, String> get userAvatars => _userAvatars;
  Map<String, String> get userPronouns => _userPronouns;
  Map<String, UserStatus> get userStatuses => _userStatuses;

  // These getters now correctly derive from the internal _channels map
  List<String> get joinedPublicChannelNames {
    return ircNetworks.expand((network) {
      return (_channels[network.id] ?? [])
          .where((channel) => channel.name.startsWith('#') && channel.members.isNotEmpty)
          .map((channel) => '${network.networkName}/${channel.name}')
          .toList();
    }).toList();
  }

  List<String> get unjoinedPublicChannelNames {
    return ircNetworks.expand((network) {
      return (_channels[network.id] ?? [])
          .where((channel) => channel.name.startsWith('#') && channel.members.isEmpty)
          .map((channel) => '${network.networkName}/${channel.name}')
          .toList();
    }).toList();
  }

  List<String> get dmChannelNames {
    return ircNetworks.expand((network) {
      return (_channels[network.id] ?? [])
          .where((channel) => channel.name.startsWith('@'))
          .map((channel) => '${network.networkName}/${channel.name}')
          .toList();
    }).toList();
  }

  ChatState() {
    // Initialization logic if needed
  }

  /// Gets messages for a channel using its full identifier (e.g., "Libera/#general" or "Libera/@user").
  List<Message> getMessagesForChannel(String channelIdentifier) {
    if (channelIdentifier.isEmpty) return [];

    final parts = channelIdentifier.split('/');
    if (parts.length < 2) return [];

    final networkName = parts[0];
    final channelName = parts.skip(1).join('/');

    final network = ircNetworks.firstWhereOrNull((net) =>
        net.networkName.toLowerCase() == networkName.toLowerCase());
    if (network == null) return [];

    final key = "${network.id}_${channelName.toLowerCase()}";
    return _messages[key] ?? [];
  }

  bool hasUnreadMessages(String channelIdentifier) {
    return _unreadStatus[channelIdentifier] ?? false;
  }

  Message? getLastMessage(String channelIdentifier) {
    final List<Message> channelMessages = getMessagesForChannel(channelIdentifier);
    return channelMessages.isNotEmpty ? channelMessages.last : null;
  }

  void addMessageBatch(int networkId, String channelIdentifier, List<Message> newMessages) {
    if (channelIdentifier.isEmpty) return;

    final parts = channelIdentifier.split('/');
    if (parts.length < 2) return;
    final networkDisplayName = parts[0]; // Not used for key, just for context
    final channelLowerCaseName = parts.skip(1).join('/').toLowerCase();

    // Ensure network exists in current state (it should have been fetched already)
    final network = ircNetworks.firstWhereOrNull((net) => net.id == networkId);
    if (network == null) {
      print("Warning: Network with ID $networkId not found for message batch on $channelIdentifier.");
      return;
    }

    final key = "${network.id}_$channelLowerCaseName";

    if (!_messages.containsKey(key)) {
      _messages[key] = [];
    }

    // Add messages ensuring no duplicates by ID
    for (var newMessage in newMessages) {
      if (!_messages[key]!.any((msg) => msg.id == newMessage.id)) {
        _messages[key]!.add(newMessage);
      }
    }

    _messages[key]!.sort((a, b) => a.time.compareTo(b.time));

    // Mark as unread only if not the currently selected conversation
    if (_selectedConversationTarget.toLowerCase() != channelIdentifier.toLowerCase()) {
      _unreadStatus[channelIdentifier] = true;
    }

    notifyListeners();
  }

  void removeDmMessage(int networkId, Message message) {
    final network = ircNetworks.firstWhereOrNull((net) => net.id == networkId);
    if (network == null) return;

    final dmChannelLowerCaseName = message.channelName.toLowerCase();
    final key = "${network.id}_$dmChannelLowerCaseName";

    _messages[key]?.removeWhere((msg) => msg.id == message.id);
    notifyListeners();
  }

  void removeDmChannel(int networkId, String rawDmChannelName) {
    final network = ircNetworks.firstWhereOrNull((net) => net.id == networkId);
    if (network == null) return;

    final dmChannelLowerCaseName = rawDmChannelName.toLowerCase();

    // Remove the channel from the _channels map
    _channels[networkId]?.removeWhere((channel) => channel.name.toLowerCase() == dmChannelLowerCaseName);

    // Remove messages associated with this DM
    final messageKey = "${networkId}_$dmChannelLowerCaseName";
    _messages.remove(messageKey);

    // Remove unread status for this DM
    final dmDisplayName = "${network.networkName}/$rawDmChannelName";
    _unreadStatus.remove(dmDisplayName);

    // If the removed DM was the currently selected conversation, clear selection.
    if (_selectedConversationTarget.toLowerCase() == dmDisplayName.toLowerCase()) {
      _selectedConversationTarget = ''; // Reset selected target
    }

    notifyListeners();
  }

  String? getPronounsForUser(String username) {
    return _userPronouns[username.toLowerCase()];
  }

  Future<void> loadPersistedMessages() async {
    // Implement persistence logic here if you want to load messages from local storage
    print("Loading persisted messages (stub, implement if needed)...");
  }

  Future<void> setIrcNetworks(List<IrcNetwork> networks) async {
    ircNetworks = networks;
    // Clear existing channels before re-populating to reflect latest server state
    _channels.clear();
    for (final network in networks) {
      _channels[network.id] = network.channels.map((ncs) => Channel(
        networkId: network.id,
        name: ncs.name,
        topic: ncs.topic,
        members: ncs.members,
        isConnected: ncs.isConnected,
      )).toList();
    }
    notifyListeners();
  }

  void addOrUpdateChannel(int networkId, Channel channel) {
    if (!_channels.containsKey(networkId)) {
      _channels[networkId] = [];
    }
    final existingIndex = _channels[networkId]!
        .indexWhere((c) => c.name.toLowerCase() == channel.name.toLowerCase());

    if (existingIndex != -1) {
      // Update existing channel
      _channels[networkId]![existingIndex] = channel;
    } else {
      // Add new channel
      _channels[networkId]!.add(channel);
    }
    notifyListeners();
  }

  void addMessage(int networkId, String channelName, Message message) {
    final key = "${networkId}_${channelName.toLowerCase()}";
    if (!_messages.containsKey(key)) {
      _messages[key] = [];
    }
    // Prevent adding duplicate messages if ID already exists (e.g., from initial state + live updates)
    if (!_messages[key]!.any((msg) => msg.id == message.id)) {
      _messages[key]!.add(message);
    }

    final network = ircNetworks.firstWhereOrNull((net) => net.id == networkId);
    if (network != null) {
      final channelIdentifier = "${network.networkName}/$channelName";
      // Only mark as unread if it's not the currently selected conversation
      if (_selectedConversationTarget.toLowerCase() != channelIdentifier.toLowerCase()) {
        _unreadStatus[channelIdentifier] = true;
      }
    }
    notifyListeners();
  }

  void addSystemMessage(int networkId, String channelIdentifier, String messageContent) {
    // Extract raw channel name from identifier
    String rawChannelName;
    final parts = channelIdentifier.split('/');
    if (parts.length > 1) {
      rawChannelName = parts.skip(1).join('/');
    } else {
      rawChannelName = channelIdentifier; // Use as-is if no network prefix
    }

    final systemMessage = Message(
      id: UniqueKey().toString(), // Unique ID for system messages
      networkId: networkId,
      channelName: rawChannelName,
      from: "System",
      content: messageContent,
      time: DateTime.now(),
      isSystemInfo: true,
      isEncrypted: false,
      isNotice: false,
    );
    addMessage(networkId, rawChannelName, systemMessage);
  }

  void updateIrcNetwork(IrcNetwork network) {
    final index = ircNetworks.indexWhere((n) => n.id == network.id);
    if (index != -1) {
      ircNetworks[index] = network;

      // =========================================================================
      // === BEGIN FIX: Re-sync the _channels map after a network is updated ===
      // =========================================================================
      // This ensures that any change to a network's channel list (like joining or
      // parting) is reflected in the central channel map that the UI uses.
      _channels[network.id] = network.channels.map((ncs) => Channel(
          networkId: network.id,
          name: ncs.name,
          topic: ncs.topic,
          members: ncs.members,
          isConnected: ncs.isConnected,
      )).toList();
      // =========================================================================
      // === END FIX =============================================================
      // =========================================================================
    }
    notifyListeners();
  }

  void removeIrcNetwork(int networkId) {
    ircNetworks.removeWhere((network) => network.id == networkId);
    _channels.remove(networkId); // Remove all channels associated with this network ID
    _messages.keys
        .toList() // Create a copy to modify the map during iteration
        .where((key) => key.startsWith('${networkId}_'))
        .forEach(_messages.remove);

    // Also remove any unread status entries associated with this network
    _unreadStatus.keys
        .toList()
        .where((key) => key.startsWith(getNetworkNameForChannel(networkId))) // This might be tricky if network is already removed from ircNetworks.
        .forEach(_unreadStatus.remove);

    notifyListeners();
  }

  void selectConversation(String target) {
    _selectedConversationTarget = target;
    _unreadStatus[_selectedConversationTarget] = false; // Mark as read
    notifyListeners();
  }

  String getNetworkNameForChannel(int networkId) {
    return ircNetworks
        .firstWhereOrNull((network) => network.id == networkId)
        ?.networkName ??
        'Unknown Network';
  }

  bool hasAvatar(String nick) {
    return _userAvatars.containsKey(nick.toLowerCase()) &&
        _userAvatars[nick.toLowerCase()]!.isNotEmpty;
  }

  void setAvatar(String nick, String url) {
    _userAvatars[nick.toLowerCase()] = url;
    notifyListeners();
  }

  void setEncryptionStatus(String target, EncryptionStatus status) {
    _encryptionSessions[target] = status;
    notifyListeners();
  }

  EncryptionStatus getEncryptionStatus(String target) {
    return _encryptionSessions[target] ?? EncryptionStatus.none;
  }

  void setUserPronouns(String username, String pronouns) {
    _userPronouns[username.toLowerCase()] = pronouns;
    notifyListeners();
  }

  void setUserStatus(String username, UserStatus status) {
    _userStatuses[username.toLowerCase()] = status;
    notifyListeners();
  }

  void clearAllMessages() {
    _messages.clear();
    _unreadStatus.clear();
    _channels.clear();
    ircNetworks.clear();
    _encryptionSessions.clear();
    _userAvatars.clear();
    _userPronouns.clear();
    _userStatuses.clear();
    _selectedConversationTarget = '';
    // No need to clear _selectedChannelIndex if it's derived
    notifyListeners();
  }
}