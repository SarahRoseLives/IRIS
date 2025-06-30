import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';
import '../models/encryption_session.dart';

class ChatState extends ChangeNotifier {
  static const String _lastChannelKey = 'last_channel';
  static const String _lastSeenKey = 'last_seen_message_ids';
  static const String _channelsKey = 'persisted_channels';
  static const String _messagesKey = 'cached_messages';
  static const String _joinedChannelsKey = 'joined_channels_list';
  static const String _pronounsKey = 'user_pronouns'; // NEW

  List<Channel> _channels = [];
  int _selectedChannelIndex = 0;
  final Map<String, List<Message>> _channelMessages = {};
  final Map<String, String?> _lastSeenMessageIds = {};
  final Map<String, String> _userAvatars = {};
  final Map<String, UserStatus> _userStatuses = {};
  final Map<String, EncryptionStatus> _encryptionStatuses = {};
  final Map<String, String> _userPronouns = {}; // NEW

  final Map<String, Set<String>> _channelDedupKeys = {};

  /// Resets the entire chat state to its initial values.
  void reset() {
    _channels = [];
    _selectedChannelIndex = 0;
    _channelMessages.clear();
    _lastSeenMessageIds.clear();
    _userAvatars.clear();
    _userStatuses.clear();
    _encryptionStatuses.clear();
    _userPronouns.clear(); // NEW
    _channelDedupKeys.clear();
    print('[ChatState] State has been reset.');
    notifyListeners();
  }

  // --- GETTERS ---
  List<Channel> get channels => _channels;
  Map<String, String> get userAvatars => _userAvatars;
  Map<String, UserStatus> get userStatuses => _userStatuses;
  Map<String, String> get userPronouns => _userPronouns; // NEW

  String? getPronounsForUser(String username) {
    return _userPronouns[username.toLowerCase()];
  }

  Message? getLastMessage(String channelName) {
    final key = channelName.toLowerCase();
    if (_channelMessages.containsKey(key) && _channelMessages[key]!.isNotEmpty) {
      return _channelMessages[key]!
          .lastWhere((m) => !m.isSystemInfo, orElse: () => _channelMessages[key]!.last);
    }
    return null;
  }

  bool hasUnreadMessages(String channelName) {
    final key = channelName.toLowerCase();
    final lastMessage = getLastMessage(key);
    if (lastMessage == null) return false;

    final lastSeenId = _lastSeenMessageIds[key];
    return lastSeenId == null || lastSeenId != lastMessage.id;
  }

  EncryptionStatus getEncryptionStatus(String channelName) {
    return _encryptionStatuses[channelName.toLowerCase()] ??
        EncryptionStatus.none;
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
    if (_channels.isNotEmpty &&
        _selectedChannelIndex < _channels.length &&
        _selectedChannelIndex >= 0) {
      return _channels[_selectedChannelIndex].name;
    }
    return "No channels";
  }

  List<ChannelMember> get membersForSelectedChannel {
    if (_channels.isNotEmpty &&
        _selectedChannelIndex < _channels.length &&
        _selectedChannelIndex >= 0) {
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

  Future<void> setUserPronouns(String username, String pronouns) async {
    _userPronouns[username.toLowerCase()] = pronouns;
    await _persistPronouns();
    notifyListeners();
  }

  Future<void> updateLastSeenMessage(String channelName) async {
    final key = channelName.toLowerCase();
    final lastMessage = getLastMessage(key);

    if (lastMessage != null) {
      if (_lastSeenMessageIds[key] != lastMessage.id) {
        _lastSeenMessageIds[key] = lastMessage.id;
        await _persistLastSeenMessageIds();
        notifyListeners();
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
    _channels
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _rebuildUserStatuses();
    _saveChannels();
    notifyListeners();
  }

  Future<void> setChannels(List<Channel> newChannels) async {
    _channels = newChannels;
    _channels
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _rebuildUserStatuses();

    final prefs = await SharedPreferences.getInstance();
    final String? lastChannelName = prefs.getString(_lastChannelKey);

    int targetIndex = -1;

    if (lastChannelName != null) {
      final lastChannelIndex = _channels
          .indexWhere((c) => c.name.toLowerCase() == lastChannelName.toLowerCase());
      if (lastChannelIndex != -1) {
        final isJoined = _channels[lastChannelIndex].name.startsWith('@') ||
            _channels[lastChannelIndex].members.isNotEmpty;
        if (isJoined) {
          targetIndex = lastChannelIndex;
        }
      }
    }

    if (targetIndex == -1) {
      targetIndex = _channels
          .indexWhere((c) => c.name.startsWith('#') && c.members.isNotEmpty);
    }
    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('@'));
    }
    if (targetIndex == -1 && _channels.isNotEmpty) {
      targetIndex = 0;
    }

    _selectedChannelIndex = (targetIndex != -1) ? targetIndex : 0;
    _saveChannels();
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
    _saveChannels();
    notifyListeners();
  }

  void updateChannelMembers(String channelName, List<ChannelMember> members) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      _channels[index].members = members;
      _rebuildUserStatuses();
      _saveChannels();
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
      _saveChannels();
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
      _saveChannels();
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
    if ((_channelDedupKeys[key] ?? {}).contains(dedupKey) &&
        !message.isSystemInfo) {
      return;
    }

    if (toEnd) {
      _channelMessages[key]!.add(message);
    } else {
      _channelMessages[key]!.insert(0, message);
    }

    _channelDedupKeys.putIfAbsent(key, () => <String>{});
    _channelDedupKeys[key]!.add(dedupKey);

    bool channelAdded = false;
    if (channelName.startsWith('@') &&
        !_channels.any((c) => c.name.toLowerCase() == key)) {
      _channels.add(Channel(name: channelName, members: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
      channelAdded = true;
    }

    notifyListeners();
    _persistMessages();
    if (channelAdded) {
      _saveChannels();
    }
  }

  void addMessageBatch(String channelName, List<Message> messages) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    final existingDedupKeys = _channelDedupKeys[key] ?? <String>{};
    final newDedupKeys = <String>{};
    final newMessages = <Message>[];

    for (var msg in messages) {
      final dedupKey = _getMessageDedupKey(msg);
      if (!existingDedupKeys.contains(dedupKey) &&
          !newDedupKeys.contains(dedupKey)) {
        newMessages.add(msg);
        newDedupKeys.add(dedupKey);
      }
    }

    if (newMessages.isNotEmpty) {
      _channelMessages[key]!.addAll(newMessages);
      _channelMessages[key]!.sort((a, b) => a.time.compareTo(b.time));

      _channelDedupKeys.putIfAbsent(key, () => <String>{});
      _channelDedupKeys[key]!.addAll(newDedupKeys);

      bool channelAdded = false;
      if (channelName.startsWith('@') &&
          !_channels.any((c) => c.name.toLowerCase() == key)) {
        _channels.add(Channel(name: channelName, members: []));
        _channels.sort((a, b) => a.name.compareTo(b.name));
        channelAdded = true;
      }

      notifyListeners();
      _persistMessages();
      if (channelAdded) {
        _saveChannels();
      }
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

  Future<void> _persistJoinedChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> joinedNames = _channels
          .where((c) =>
              c.name.startsWith('@') ||
              (c.name.startsWith('#') && c.members.isNotEmpty))
          .map((c) => c.name)
          .toList();
      await prefs.setStringList(_joinedChannelsKey, joinedNames);
    } catch (e) {
      print('Error persisting joined channels: $e');
    }
  }

  Future<List<String>> loadPersistedJoinedChannels() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_joinedChannelsKey) ?? [];
  }

  Future<void> _saveChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> channelsJson =
          _channels.map((c) => c.toJson()).toList();
      await prefs.setString(_channelsKey, json.encode(channelsJson));
      await _persistJoinedChannels();
    } catch (e) {
      print(
          'Error saving channels to prefs: $e. Make sure Channel.toJson() is implemented.');
    }
  }

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
    await prefs.setString(_messagesKey, json.encode(messagesToSave));
  }

  Future<void> _persistPronouns() async { // NEW
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pronounsKey, json.encode(_userPronouns));
  }

  Future<void> loadPersistedMessages() async {
    final prefs = await SharedPreferences.getInstance();

    final savedChannels = prefs.getString(_channelsKey);
    if (savedChannels != null) {
      try {
        final channelsJson = json.decode(savedChannels) as List<dynamic>;
        _channels = channelsJson
            .map((c) => Channel.fromJson(c as Map<String, dynamic>))
            .toList();
        _rebuildUserStatuses();
      } catch (e) {
        print('Error loading persisted channels: $e');
      }
    }

    _channelMessages.clear();
    _channelDedupKeys.clear();
    final savedMessages = prefs.getString(_messagesKey);
    if (savedMessages != null) {
      try {
        final messagesMap = json.decode(savedMessages) as Map<String, dynamic>;
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

    // NEW: Load persisted pronouns
    _userPronouns.clear();
    final savedPronouns = prefs.getString(_pronounsKey);
    if (savedPronouns != null) {
      try {
        final pronounsMap = json.decode(savedPronouns) as Map<String, dynamic>;
        pronounsMap.forEach((key, value) {
          _userPronouns[key] = value as String;
        });
      } catch (e) {
        print('Error loading persisted pronouns: $e');
      }
    }

    notifyListeners();
  }

  void removeDmMessage(Message message) {
    final target = selectedConversationTarget.toLowerCase();
    if (_channelMessages.containsKey(target)) {
      _channelMessages[target]!.removeWhere((m) => m.id == message.id);
      _persistMessages();
      notifyListeners();
    }
  }

  void removeDmChannel(String channelName) {
    final key = channelName.toLowerCase();

    _channels.removeWhere((c) => c.name.toLowerCase() == key);
    _channelMessages.remove(key);
    _channelDedupKeys.remove(key);
    _lastSeenMessageIds.remove(key);
    _encryptionStatuses.remove(key);

    _persistMessages();
    _persistLastSeenMessageIds();
    _saveChannels();

    notifyListeners();
  }

  void updateChannelTopic(String channelName, String newTopic) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      _channels[index] = Channel(
        name: _channels[index].name,
        topic: newTopic,
        members: _channels[index].members,
      );
      _saveChannels();
      notifyListeners();
    }
  }
}