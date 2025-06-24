import 'channel_member.dart';

/// Represents a single chat message.
class Message {
  final String from;
  final String content;
  final DateTime time;
  final String id;
  final bool isHistorical;

  Message({
    required this.from,
    required this.content,
    required this.time,
    required this.id,
    this.isHistorical = false,
  });

  /// Creates a Message object from a JSON map.
  factory Message.fromJson(Map<String, dynamic> json) {
    final String from = json['from'] ?? 'Unknown';
    final String timeStr = json['time'] ?? '';
    final bool isHist = json['isHistorical'] ?? false;
    final String? id = json['id'];

    // NEW: Generate consistent ID using channel + time (seconds) + sender
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
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'from': from,
      'content': content,
      'time': time.toIso8601String(),
      'id': id,
      'isHistorical': isHistorical,
    };
  }
}

/// Represents an IRC channel, including its members.
class Channel {
  final String name;
  List<ChannelMember> members;

  Channel({
    required this.name,
    required this.members,
  });

  factory Channel.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members = memberList.map((i) => ChannelMember.fromJson(i)).toList();

    return Channel(
      name: json['name'] ?? '',
      members: members,
    );
  }
}