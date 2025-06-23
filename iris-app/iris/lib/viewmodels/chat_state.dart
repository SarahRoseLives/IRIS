import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/channel_member.dart';
import '../models/user_status.dart';

class ChatState extends ChangeNotifier {
  List<Channel> _channels = [];
  int _selectedChannelIndex = 0;
  final Map<String, List<Message>> _channelMessages = {};
  final Map<String, String> _userAvatars = {};
  final Map<String, UserStatus> _userStatuses = {};

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
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].name;
    }
    return "No channels";
  }

  List<ChannelMember> get membersForSelectedChannel {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].members;
    }
    return [];
  }

  List<Message> get messagesForSelectedChannel {
    final target = selectedConversationTarget.toLowerCase();
    return _channelMessages[target] ?? [];
  }

  bool hasAvatar(String username) => _userAvatars.containsKey(username) && _userAvatars[username]!.isNotEmpty;

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

  void setChannels(List<Channel> newChannels, {String? defaultChannel}) {
    _channels = newChannels;
    _channels.sort((a, b) => a.name.compareTo(b.name));

    _rebuildUserStatuses();

    int targetIndex = -1;

    if (defaultChannel != null) {
      targetIndex = _channels.indexWhere((c) => c.name.toLowerCase() == defaultChannel.toLowerCase());
    }

    if (targetIndex == -1) {
      targetIndex = _channels.indexWhere((c) => c.name.startsWith('#'));
    }

    _selectedChannelIndex = (targetIndex >= 0 && targetIndex < _channels.length) ? targetIndex : 0;
    notifyListeners();
  }

  void addOrUpdateChannel(Channel channel) {
    final index = _channels.indexWhere((c) => c.name.toLowerCase() == channel.name.toLowerCase());
    if (index != -1) {
      _channels[index] = channel;
    } else {
      _channels.add(channel);
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }
    _rebuildUserStatuses();
    notifyListeners();
  }

  void removeChannel(String channelName) {
    final initialTarget = selectedConversationTarget;
    _channels.removeWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());

    if (initialTarget.toLowerCase() == channelName.toLowerCase()) {
      final newIndex = _channels.indexWhere((c) => c.name.startsWith("#"));
      _selectedChannelIndex = (newIndex != -1) ? newIndex : 0;
    }
    _rebuildUserStatuses();
    notifyListeners();
  }

  void updateChannelMembers(String channelName, List<ChannelMember> members) {
    final index = _channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (index != -1) {
      _channels[index].members = members;
      _rebuildUserStatuses();
      notifyListeners();
    }
  }

  void selectConversation(String conversationName) {
    final index = _channels.indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;
      notifyListeners();
    }
  }

  void addMessage(String channelName, Message message, {bool toEnd = true}) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    if (!_channelMessages[key]!.any((m) => m.id == message.id)) {
      if (toEnd) {
         _channelMessages[key]!.add(message);
      } else {
         _channelMessages[key]!.insert(0, message);
      }
      notifyListeners();
      _persistMessages();
    }
  }

  void addMessageBatch(String channelName, List<Message> messages) {
    final key = channelName.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);

    // Deduplicate using message IDs
    final existingIds = _channelMessages[key]!.map((m) => m.id).toSet();
    final newMessages = messages.where((m) => !existingIds.contains(m.id)).toList();

    // Sort by time ascending (oldest first)
    newMessages.sort((a, b) => a.time.compareTo(b.time));
    if (newMessages.isNotEmpty) {
      _channelMessages[key]!.addAll(newMessages); // <-- append to the end, not the start!
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

  Future<void> loadPersistedMessages() async {
    final prefs = await SharedPreferences.getInstance();
    _channelMessages.clear();
    final saved = prefs.getString('cached_messages');
    if (saved != null) {
      try {
        final messagesMap = json.decode(saved) as Map<String, dynamic>;
        messagesMap.forEach((channel, messages) {
          final messageList =
              (messages as List).map((m) => Message.fromJson(m)).toList();
          _channelMessages[channel] = messageList;
        });
        notifyListeners();
      } catch (e) {
        print('Error loading persisted messages: $e');
      }
    }
  }
}