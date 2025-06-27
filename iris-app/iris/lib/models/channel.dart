import 'channel_member.dart';

/// Represents a single chat message.
class Message {
  final String from;
  final String content;
  final DateTime time;
  final String id;
  final bool isHistorical;
  final bool isEncrypted; // NEW
  final bool isSystemInfo; // NEW

  Message({
    required this.from,
    required this.content,
    required this.time,
    required this.id,
    this.isHistorical = false,
    this.isEncrypted = false, // NEW
    this.isSystemInfo = false, // NEW
  });

  /// Creates a Message object from a JSON map.
  factory Message.fromJson(Map<String, dynamic> json) {
    final String from = json['from'] ?? 'Unknown';
    final String timeStr = json['time'] ?? '';
    final bool isHist = json['isHistorical'] ?? false;
    final String? id = json['id'];

    final channel = json['channel_name'] ?? '';
    final time = DateTime.tryParse(timeStr)?.toLocal() ?? DateTime.now();
    final seconds = time.millisecondsSinceEpoch ~/ 1000;

    return Message(
      from: from,
      content: json['content'] ?? '',
      time: time,
      id: id ??
          (isHist
              ? 'hist-$channel-$seconds-$from'
              : 'real-$channel-$seconds-$from'),
      isHistorical: isHist,
      isEncrypted: json['isEncrypted'] ?? false, // NEW
      isSystemInfo: json['isSystemInfo'] ?? false, // NEW
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'from': from,
      'content': content,
      'time': time.toIso8601String(),
      'id': id,
      'isHistorical': isHistorical,
      'isEncrypted': isEncrypted, // NEW
      'isSystemInfo': isSystemInfo, // NEW
    };
  }
}

/// Represents an IRC channel, including its members and topic.
class Channel {
  final String name;
  final String topic; // Added topic field
  List<ChannelMember> members;

  Channel({
    required this.name,
    this.topic = '', // Default to empty string
    required this.members,
  });

  factory Channel.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members = memberList.map((i) => ChannelMember.fromJson(i)).toList();

    return Channel(
      name: json['name'] ?? '',
      topic: json['topic'] ?? '', // Parse topic from JSON
      members: members,
    );
  }

  // START OF CHANGE
  /// Converts a Channel instance to a JSON map for persistence.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'topic': topic,
      // This requires the ChannelMember class to also have a toJson() method.
      'members': members.map((m) => m.toJson()).toList(),
    };
  }
  // END OF CHANGE
}