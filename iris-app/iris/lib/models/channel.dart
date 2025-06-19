// lib/models/channel.dart

import 'channel_member.dart';

/// Represents a single chat message.
class Message {
  final String from;
  final String content;
  final DateTime time;
  // A unique ID is helpful for list keys and other operations.
  final String id;

  Message({
    required this.from,
    required this.content,
    required this.time,
    required this.id,
  });

  /// Creates a Message object from a JSON map.
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      from: json['from'] ?? 'Unknown',
      content: json['content'] ?? '',
      // Ensure time is parsed correctly and converted to local time.
      time: DateTime.tryParse(json['time'] ?? '')?.toLocal() ?? DateTime.now(),
      // If an ID isn't provided by the backend, create a fallback unique value.
      id: (json['id'] ?? DateTime.now().millisecondsSinceEpoch).toString(),
    );
  }

  /// Helper to convert to a Map, useful for sending data or debugging.
  Map<String, dynamic> toMap() {
    return {
      'from': from,
      'content': content,
      'time': time.toIso8601String(),
      'id': id,
    };
  }
}

/// Represents an IRC channel, including its members and message history.
class Channel {
  final String name;
  List<ChannelMember> members;
  List<Message> messages; // MODIFIED: This now holds a list of Message objects.

  Channel({
    required this.name,
    required this.members,
    required this.messages, // MODIFIED: Added to constructor.
  });

  /// MODIFIED: Updated fromJson factory to parse the full channel state,
  /// including the list of messages.
  factory Channel.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members = memberList.map((i) => ChannelMember.fromJson(i)).toList();

    var messageList = json['messages'] as List? ?? [];
    List<Message> messages = messageList.map((m) => Message.fromJson(m)).toList();

    return Channel(
      name: json['name'] ?? '',
      members: members,
      messages: messages, // Assign the parsed messages.
    );
  }
}
