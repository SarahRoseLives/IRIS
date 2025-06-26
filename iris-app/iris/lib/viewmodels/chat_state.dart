import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import '../models/encryption_session.dart';

class ChatState extends ChangeNotifier {
  static const String _lastChannelKey = 'last_channel';
  // NEW: Key for persisting last seen message IDs
  static const String _lastSeenKey = 'last_seen_message_ids';

  List<Channel> _channels = [];
  int _selectedChannelIndex = 0;
  final Map<String, List<Message>> _channelMessages = {};
  // NEW: Map to store the ID of the last seen message per channel
  final Map<String, String?> _lastSeenMessageIds = {};
  final Map<String, String> _userAvatars = {};
  final Map<String, UserStatus> _userStatuses = {};
  final Map<String, EncryptionStatus> _encryptionStatuses = {};

  final Map<String, Set<String>> _channelDedupKeys = {};

  // --- GETTERS ---
  List<Channel> get channels => _channels;
  Map<String, String> get userAvatars => _userAvatars;
  Map<String, UserStatus> get userStatuses => _userStatuses;

  // NEW: Getter for the last message in a channel
  Message? getLastMessage(String channelName) {
    final key = channelName.toLowerCase();
    if (_channelMessages.containsKey(key) && _channelMessages[key]!.isNotEmpty) {
      // Find the last message that is not system info
      return _channelMessages[key]!.lastWhere((m) => !m.isSystemInfo, orElse: () => _channelMessages[key]!.last);
    }
    return null;
  }

  // NEW: Check if a channel has unread messages
  bool hasUnreadMessages(String channelName) {
    final key = channelName.toLowerCase();
    final lastMessage = getLastMessage(key);
    // No messages or only system messages means no "unread" state
    if (lastMessage == null) return false;

    final lastSeenId = _lastSeenMessageIds[key];
    // If we have never seen a message in this channel, or the last message ID is different, it's unread.
    return lastSeenId == null || lastSeenId != lastMessage.id;
  }

  EncryptionStatus getEncryptionStatus(String channelName) {
    return _encryptionStatuses[channelName.toLowerCase()] ?? EncryptionStatus.none;
  }

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

  List<Message> getMessagesForChannel(String channelName) {
    final key = channelName.toLowerCase();
    return _channelMessages[key] ?? [];
  }

  bool hasAvatar(String username) =>
      _userAvatars.containsKey(username) && _userAvatars[username]!.isNotEmpty;

  // --- MUTATORS ---

  // NEW: Method to update the last seen message ID for a channel.
  Future<void> updateLastSeenMessage(String channelName) async {
    final key = channelName.toLowerCase();
    final lastMessage = getLastMessage(key);

    if (lastMessage != null) {
      if (_lastSeenMessageIds[key] != lastMessage.id) {
        _lastSeenMessageIds[key] = lastMessage.id;
        await _persistLastSeenMessageIds();
        notifyListeners(); // Notify listeners that the unread state might have changed
      }
    }
  }

  void setEncryptionStatus(String channelName, EncryptionStatus status) {
      _encryptionStatuses[channelName.toLowerCase()] = status;
      notifyListeners();
  }

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

  void mergeChannels(List<Channel> channelsToMerge) {
    final Map<String, Channel> channelMap = {
      for (var c in _channels) c.name.toLowerCase(): c
    };

    for (final incomingChannel in channelsToMerge) {
      channelMap[incomingChannel.name.toLowerCase()] = incomingChannel;
    }

    _channels = channelMap.values.toList();
    _channels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _rebuildUserStatuses();
    notifyListeners();
  }

  Future<void> setChannels(List<Channel> newChannels) async {
    _channels = newChannels;
    _channels.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _rebuildUserStatuses();

    final prefs = await SharedPreferences.getInstance();
    final String? lastChannelName = prefs.getString(_lastChannelKey);

    int targetIndex = -1;

    if (lastChannelName != null) {
      final lastChannelIndex = _channels.indexWhere((c) => c.name.toLowerCase() == lastChannelName.toLowerCase());
      if (lastChannelIndex != -1) {
        final isJoined = _channels[lastChannelIndex].name.startsWith('@') || _channels[lastChannelIndex].members.isNotEmpty;
        if (isJoined) {
          targetIndex = lastChannelIndex;
        }
      }
    }

    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('#') && c.members.isNotEmpty);
    }
    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('@'));
    }
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

  void updateChannelMembers(String channelName, List<ChannelMember> members) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      _channels[index].members = members;
      _rebuildUserStatuses();
      notifyListeners();
    }
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
      if (_selectedChannelIndex == index) {
        final newIndex = _channels
            .indexWhere((c) => c.name.startsWith('#') && c.members.isNotEmpty);
        _selectedChannelIndex = (newIndex != -1) ? newIndex : 0;
      }
      _rebuildUserStatuses();
      notifyListeners();
    }
  }

  void selectConversation(String conversationName) async {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastChannelKey, conversationName);
      // NEW: When a channel is selected, update its last seen message ID.
      await updateLastSeenMessage(conversationName);
      notifyListeners();
    }
  }

  String _getMessageDedupKey(Message msg) {
    return '${msg.from}|${msg.content}';
  }

  void addMessage(String channelName, Message message, {bool toEnd = true}) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    final dedupKey = _getMessageDedupKey(message);
    if ((_channelDedupKeys[key] ?? {}).contains(dedupKey) && !message.isSystemInfo) {
      return;
    }

    if (toEnd) {
      _channelMessages[key]!.add(message);
    } else {
      _channelMessages[key]!.insert(0, message);
    }

    _channelDedupKeys.putIfAbsent(key, () => <String>{});
    _channelDedupKeys[key]!.add(dedupKey);

    if (channelName.startsWith('@') &&
        !_channels.any((c) => c.name.toLowerCase() == key)) {
      _channels.add(Channel(name: channelName, members: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }

    notifyListeners();
    _persistMessages();
  }

  void addMessageBatch(String channelName, List<Message> messages) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    final existingDedupKeys = _channelDedupKeys[key] ?? <String>{};
    final newDedupKeys = <String>{};
    final newMessages = <Message>[];

    for (var msg in messages) {
      final dedupKey = _getMessageDedupKey(msg);
      if (!existingDedupKeys.contains(dedupKey) && !newDedupKeys.contains(dedupKey)) {
        newMessages.add(msg);
        newDedupKeys.add(dedupKey);
      }
    }

    if (newMessages.isNotEmpty) {
      _channelMessages[key]!.addAll(newMessages);
      _channelMessages[key]!.sort((a, b) => a.time.compareTo(b.time));

      _channelDedupKeys.putIfAbsent(key, () => <String>{});
      _channelDedupKeys[key]!.addAll(newDedupKeys);

      if (channelName.startsWith('@') &&
          !_channels.any((c) => c.name.toLowerCase() == key)) {
        _channels.add(Channel(name: channelName, members: []));
        _channels.sort((a, b) => a.name.compareTo(b.name));
      }

      notifyListeners();
      _persistMessages();
    }
  }

  void addSystemMessage(String channelName, String message) {
    if (channelName.isEmpty) return;
    final infoMessage = Message(
        from: 'IRIS Bot',
        content: message,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        isSystemInfo: true);
    addMessage(channelName, infoMessage);
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

  // NEW: Method to save the last seen message IDs to SharedPreferences.
  Future<void> _persistLastSeenMessageIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSeenKey, json.encode(_lastSeenMessageIds));
  }

  Future<void> _persistMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesToSave = <String, dynamic>{};
    _channelMessages.forEach((channel, messages) {
      messagesToSave[channel] = messages.map((m) => m.toMap()).toList();
    });
    await prefs.setString('cached_messages', json.encode(messagesToSave));
  }

  Future<void> loadPersistedMessages() async {
    final prefs = await SharedPreferences.getInstance();
    _channelMessages.clear();
    _channelDedupKeys.clear();
    final saved = prefs.getString('cached_messages');
    if (saved != null) {
      try {
        final messagesMap = json.decode(saved) as Map<String, dynamic>;
        messagesMap.forEach((channel, messages) {
          final messageList =
              (messages as List).map((m) => Message.fromJson(m)).toList();
          _channelMessages[channel] = messageList;

          final dedupKeys = <String>{};
          for (var msg in messageList) {
            dedupKeys.add(_getMessageDedupKey(msg));
          }
          _channelDedupKeys[channel] = dedupKeys;

          if (channel.startsWith('@') &&
              !_channels.any((c) => c.name.toLowerCase() == channel.toLowerCase())) {
            _channels.add(Channel(name: channel, members: []));
            _channels.sort((a, b) => a.name.compareTo(b.name));
          }
        });
      } catch (e) {
        print('Error loading persisted messages: $e');
      }
    }

    // NEW: Load last seen message IDs
    _lastSeenMessageIds.clear();
    final savedSeenIds = prefs.getString(_lastSeenKey);
    if (savedSeenIds != null) {
        try {
            final seenIdsMap = json.decode(savedSeenIds) as Map<String, dynamic>;
            seenIdsMap.forEach((key, value) {
                _lastSeenMessageIds[key] = value as String?;
            });
        } catch (e) {
            print('Error loading last seen message IDs: $e');
        }
    }

    notifyListeners();
  }

  // --- DM Message Removal ---

  void removeDmMessage(Message message) {
    final target = selectedConversationTarget.toLowerCase();
    if (_channelMessages.containsKey(target)) {
      _channelMessages[target]!.removeWhere((m) => m.id == message.id);
      _persistMessages();
      notifyListeners();
    }
  }

  // --- DM Channel Removal ---
  void removeDmChannel(String channelName) {
    final key = channelName.toLowerCase();

    // Remove from channels
    _channels.removeWhere((c) => c.name.toLowerCase() == key);

    // Remove messages
    _channelMessages.remove(key);

    // Remove dedup keys
    _channelDedupKeys.remove(key);

    // Remove last seen
    _lastSeenMessageIds.remove(key);

    // Remove encryption status if present
    _encryptionStatuses.remove(key);

    _persistMessages();
    _persistLastSeenMessageIds();

    notifyListeners();
  }
}