import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';

class ChatState extends ChangeNotifier {
  static const String _lastChannelKey = 'last_channel'; // Key for persistence

  List<Channel> _channels = [];
  int _selectedChannelIndex = 0;
  final Map<String, List<Message>> _channelMessages = {};
  final Map<String, String> _userAvatars = {};
  final Map<String, UserStatus> _userStatuses = {};

  // --- NEW: Triple deduplication map ---
  final Map<String, Set<String>> _channelTriples = {};

  // --- GETTERS ---
  List<Channel> get channels => _channels;
  Map<String, String> get userAvatars => _userAvatars;
  Map<String, UserStatus> get userStatuses => _userStatuses;

  List<String> get joinedPublicChannelNames => _channels
      .where((c) => c.name.startsWith('#') && c.members.isNotEmpty)
      .map((c) => c.name)
      .toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  List<String> get unjoinedPublicChannelNames => _channels
      .where((c) => c.name.startsWith('#') && c.members.isEmpty)
      .map((c) => c.name)
      .toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  List<String> get dmChannelNames =>
      _channels.where((c) => c.name.startsWith('@')).map((c) => c.name).toList();

  String get selectedConversationTarget {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length && _selectedChannelIndex >= 0) {
      return _channels[_selectedChannelIndex].name;
    }
    return "No channels";
  }

  List<ChannelMember> get membersForSelectedChannel {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length && _selectedChannelIndex >= 0) {
      return _channels[_selectedChannelIndex].members;
    }
    return [];
  }

  List<Message> get messagesForSelectedChannel {
    final target = selectedConversationTarget.toLowerCase();
    return _channelMessages[target] ?? [];
  }

  // --- PATCH: Helper to retrieve messages for ANY channel
  List<Message> getMessagesForChannel(String channelName) {
    final key = channelName.toLowerCase();
    return _channelMessages[key] ?? [];
  }

  bool hasAvatar(String username) =>
      _userAvatars.containsKey(username) && _userAvatars[username]!.isNotEmpty;

  ChannelMember? getMemberInCurrentChannel(String nick) {
    final members = membersForSelectedChannel;
    try {
      return members.firstWhere((m) => m.nick.toLowerCase() == nick.toLowerCase());
    } catch (e) {
      return null;
    }
  }

  UserStatus getUserStatus(String username) {
    final lowerCaseUsername = username.toLowerCase();
    for (var entry in _userStatuses.entries) {
      if (entry.key.toLowerCase() == lowerCaseUsername) {
        return entry.value;
      }
    }
    return UserStatus.offline;
  }

  // --- MUTATORS ---

  void _rebuildUserStatuses() {
    _userStatuses.clear();
    for (final channel in _channels) {
      for (final member in channel.members) {
        if (member.isAway) {
          _userStatuses[member.nick] = UserStatus.away;
        } else {
          _userStatuses.putIfAbsent(member.nick, () => UserStatus.online);
        }
      }
    }
  }

  // --- NEW: Merge channels intelligently (cache/server/websocket)
  void mergeChannels(List<Channel> channelsToMerge) {
    // Use a map for efficient lookup and to handle duplicates
    final Map<String, Channel> channelMap = {
      for (var c in _channels) c.name.toLowerCase(): c
    };

    // Add or update channels from the incoming list.
    // If a channel is in both lists, the incoming one (from the server/websocket) wins,
    // as it's considered more up-to-date.
    for (final incomingChannel in channelsToMerge) {
      channelMap[incomingChannel.name.toLowerCase()] = incomingChannel;
    }

    // Convert the merged map back to a list and sort it
    _channels = channelMap.values.toList();
    _channels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _rebuildUserStatuses();
    notifyListeners();
  }

  /// MODIFIED: This method now contains the complete logic for setting the initial channel.
  Future<void> setChannels(List<Channel> newChannels) async {
    _channels = newChannels;
    // Sort channels alphabetically for consistent ordering in the UI.
    _channels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _rebuildUserStatuses();

    final prefs = await SharedPreferences.getInstance();
    final String? lastChannelName = prefs.getString(_lastChannelKey);

    int targetIndex = -1;

    // 1. Try to find the last visited channel, but only if it's still a joined channel.
    if (lastChannelName != null) {
      final lastChannelIndex = _channels.indexWhere((c) => c.name.toLowerCase() == lastChannelName.toLowerCase());
      if (lastChannelIndex != -1) {
        // A DM is always considered 'joined'. A public channel is joined if it has members.
        final isJoined = _channels[lastChannelIndex].name.startsWith('@') || _channels[lastChannelIndex].members.isNotEmpty;
        if (isJoined) {
          targetIndex = lastChannelIndex;
        }
      }
    }

    // 2. If no valid last channel, find the first joined public channel.
    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('#') && c.members.isNotEmpty);
    }

    // 3. If still no channel, find the first DM.
    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('@'));
    }

    // 4. As a final fallback, if we still have nothing (e.g., only unjoined channels exist),
    // just pick the first one to avoid an error state.
    if (targetIndex == -1 && _channels.isNotEmpty) {
      targetIndex = 0;
    }

    _selectedChannelIndex = (targetIndex != -1) ? targetIndex : 0;
    notifyListeners();
  }

  void addOrUpdateChannel(Channel channel) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channel.name.toLowerCase());
    if (index != -1) {
      _channels[index] = channel;
    } else {
      _channels.add(channel);
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }
    _rebuildUserStatuses();
    notifyListeners();
  }

  void moveChannelToJoined(String channelName, String username) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      final channel = _channels[index];
      if (!channel.members
          .any((m) => m.nick.toLowerCase() == username.toLowerCase())) {
        channel.members
            .add(ChannelMember(nick: username, prefix: '', isAway: false));
      }
      _channels[index] = channel;
      _rebuildUserStatuses();
      notifyListeners();
    }
  }

  void moveChannelToUnjoined(String channelName) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      final channel = _channels[index];
      channel.members = [];
      _channels[index] = channel;
      // If currently selected, move to another joined channel if possible
      if (_selectedChannelIndex == index) {
        final newIndex = _channels
            .indexWhere((c) => c.name.startsWith('#') && c.members.isNotEmpty);
        _selectedChannelIndex = (newIndex != -1) ? newIndex : 0;
      }
      _rebuildUserStatuses();
      notifyListeners();
    }
  }

  void removeChannel(String channelName) {
    final initialTarget = selectedConversationTarget;
    _channels.removeWhere(
        (c) => c.name.toLowerCase() == channelName.toLowerCase());

    if (initialTarget.toLowerCase() == channelName.toLowerCase()) {
      final newIndex =
          _channels.indexWhere((c) => c.name.startsWith("#"));
      _selectedChannelIndex = (newIndex != -1) ? newIndex : 0;
    }
    _rebuildUserStatuses();
    notifyListeners();
  }

  void updateChannelMembers(String channelName, List<ChannelMember> members) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      _channels[index].members = members;
      _rebuildUserStatuses();
      notifyListeners();
    }
  }

  /// MODIFIED: Made async and saves the channel name to SharedPreferences.
  void selectConversation(String conversationName) async {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;

      // Persist the selected channel name
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastChannelKey, conversationName);

      notifyListeners();
    }
  }

  // --- NEW: Helper for message triple ---
  String _getMessageTriple(Message msg) {
    int seconds = msg.time.millisecondsSinceEpoch ~/ 1000;
    return '${msg.from}|${msg.content}|$seconds';
  }

  // --- MODIFIED: Add message with triple check + DM channel auto-creation
  void addMessage(String channelName, Message message, {bool toEnd = true}) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    // Triple-based deduplication
    final triple = _getMessageTriple(message);
    if ((_channelTriples[key] ?? {}).contains(triple)) {
      return; // duplicate message
    }

    if (toEnd) {
      _channelMessages[key]!.add(message);
    } else {
      _channelMessages[key]!.insert(0, message);
    }

    _channelTriples.putIfAbsent(key, () => <String>{});
    _channelTriples[key]!.add(triple);

    // --- PATCH: If a DM message arrives for a channel not in the channel list, create the DM channel.
    if (channelName.startsWith('@') &&
        !_channels.any((c) => c.name.toLowerCase() == key)) {
      _channels.add(Channel(name: channelName, members: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }

    notifyListeners();
    _persistMessages();
  }

  // --- MODIFIED: Batch add with triple deduplication + DM channel auto-creation
  void addMessageBatch(String channelName, List<Message> messages) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    final existingTriples = _channelTriples[key] ?? <String>{};
    final newTriples = <String>{};
    final newMessages = <Message>[];

    for (var msg in messages) {
      final triple = _getMessageTriple(msg);
      if (!existingTriples.contains(triple) && !newTriples.contains(triple)) {
        newMessages.add(msg);
        newTriples.add(triple);
      }
    }

    if (newMessages.isNotEmpty) {
      _channelMessages[key]!.addAll(newMessages);
      _channelMessages[key]!.sort((a, b) => a.time.compareTo(b.time)); // Ensure ordering

      _channelTriples.putIfAbsent(key, () => <String>{});
      _channelTriples[key]!.addAll(newTriples);

      // --- PATCH: If a DM message arrives for a channel not in the channel list, create the DM channel.
      if (channelName.startsWith('@') &&
          !_channels.any((c) => c.name.toLowerCase() == key)) {
        _channels.add(Channel(name: channelName, members: []));
        _channels.sort((a, b) => a.name.compareTo(b.name));
      }

      notifyListeners();
      _persistMessages();
    }
  }

  void addInfoMessage(String message) {
    final currentChannel = selectedConversationTarget;
    if (currentChannel == "No channels") return;
    final infoMessage = Message(
        from: 'IRIS Bot',
        content: message,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString());
    addMessage(currentChannel, infoMessage);
  }

  void setAvatar(String username, String url) {
    if (username.isNotEmpty) {
      _userAvatars[username] = url;
      notifyListeners();
    }
  }

  void setAvatarPlaceholder(String username) {
    if (username.isNotEmpty && !_userAvatars.containsKey(username)) {
      _userAvatars[username] = '';
    }
  }

  // --- PERSISTENCE ---
  Future<void> _persistMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesToSave = <String, dynamic>{};
    _channelMessages.forEach((channel, messages) {
      messagesToSave[channel] = messages.map((m) => m.toMap()).toList();
    });
    await prefs.setString('cached_messages', json.encode(messagesToSave));
  }

  // --- MODIFIED: Rebuild triples on load ---
  Future<void> loadPersistedMessages() async {
    final prefs = await SharedPreferences.getInstance();
    _channelMessages.clear();
    _channelTriples.clear();
    final saved = prefs.getString('cached_messages');
    if (saved != null) {
      try {
        final messagesMap = json.decode(saved) as Map<String, dynamic>;
        messagesMap.forEach((channel, messages) {
          final messageList =
              (messages as List).map((m) => Message.fromJson(m)).toList();
          _channelMessages[channel] = messageList;

          final triples = <String>{};
          for (var msg in messageList) {
            triples.add(_getMessageTriple(msg));
          }
          _channelTriples[channel] = triples;

          // --- PATCH: Ensure DM channels exist in _channels if there are messages for them
          if (channel.startsWith('@') &&
              !_channels.any((c) => c.name.toLowerCase() == channel.toLowerCase())) {
            _channels.add(Channel(name: channel, members: []));
            _channels.sort((a, b) => a.name.compareTo(b.name));
          }
        });
        notifyListeners();
      } catch (e) {
        print('Error loading persisted messages: $e');
      }
    }
  }
}