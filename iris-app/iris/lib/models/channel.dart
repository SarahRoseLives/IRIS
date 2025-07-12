import 'channel_member.dart';

/// Represents a single chat message.
class Message {
  final int networkId;
  final String channelName; // Added: Represents the channel this message belongs to (e.g., #general, @user)
  final String from;
  String content; // Made mutable for decryption/local changes
  final DateTime time;
  final String id;
  final bool isHistorical;
  final bool isEncrypted;
  final bool isSystemInfo;
  final bool isNotice;

  Message({
    required this.networkId,
    required this.channelName, // Added to constructor
    required this.from,
    required this.content,
    required this.time,
    required this.id,
    this.isHistorical = false,
    this.isEncrypted = false,
    this.isSystemInfo = false,
    this.isNotice = false,
  });

  // Added copyWith for easier modification without recreating the entire object
  Message copyWith({
    int? networkId,
    String? channelName,
    String? from,
    String? content,
    DateTime? time,
    String? id,
    bool? isHistorical,
    bool? isEncrypted,
    bool? isSystemInfo,
    bool? isNotice,
  }) {
    return Message(
      networkId: networkId ?? this.networkId,
      channelName: channelName ?? this.channelName,
      from: from ?? this.from,
      content: content ?? this.content,
      time: time ?? this.time,
      id: id ?? this.id,
      isHistorical: isHistorical ?? this.isHistorical,
      isEncrypted: isEncrypted ?? this.isEncrypted,
      isSystemInfo: isSystemInfo ?? this.isSystemInfo,
      isNotice: isNotice ?? this.isNotice,
    );
  }

  /// Creates a Message object from a JSON map.
  factory Message.fromJson(Map<String, dynamic> json) {
    final int networkId = json['network_id'] as int? ?? 0;
    final String from = json['sender'] as String? ?? json['from'] as String? ?? 'Unknown';
    final String timeStr = json['timestamp'] as String? ?? json['time'] as String? ?? '';
    final bool isHist = json['isHistorical'] as bool? ?? false;
    final String? id = json['id'] as String?;

    // Ensure 'channel_name' or 'channel' is available for channelName and ID generation if 'id' is null
    final String parsedChannelName = json['channel_name'] as String? ?? json['channel'] as String? ?? ''; // Renamed local var

    final time = DateTime.tryParse(timeStr)?.toLocal() ?? DateTime.now();
    final seconds = time.millisecondsSinceEpoch ~/ 1000;

    return Message(
      networkId: networkId,
      channelName: parsedChannelName, // Pass the parsed channel name
      from: from,
      content: json['text'] as String? ?? json['content'] as String? ?? '',
      time: time,
      id: id ??
          (isHist
              ? 'hist-${networkId}-${parsedChannelName}-${seconds}-${from}' // Use parsedChannelName and networkId for more unique ID
              : 'real-${networkId}-${parsedChannelName}-${seconds}-${from}'), // Use parsedChannelName and networkId for more unique ID
      isHistorical: isHist,
      isEncrypted: json['isEncrypted'] as bool? ?? false,
      isSystemInfo: json['isSystemInfo'] as bool? ?? false,
      isNotice: json['isNotice'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'network_id': networkId,
      'channel_name': channelName, // Include channelName
      'from': from,
      'content': content,
      'time': time.toIso8601String(),
      'id': id,
      'isHistorical': isHistorical,
      'isEncrypted': isEncrypted,
      'isSystemInfo': isSystemInfo,
      'isNotice': isNotice,
    };
  }
}

/// Represents an IRC channel, including its members and topic.
class Channel {
  final int networkId;
  final String name;
  final String topic;
  final List<ChannelMember> members; // Make final and use copyWith
  final bool isConnected;

  Channel({
    required this.networkId,
    required this.name,
    this.topic = '',
    required this.members,
    this.isConnected = false,
  });

  // Add a copyWith method to create a new instance with updated values
  Channel copyWith({
    int? networkId,
    String? name,
    String? topic,
    List<ChannelMember>? members,
    bool? isConnected,
  }) {
    return Channel(
      networkId: networkId ?? this.networkId,
      name: name ?? this.name,
      topic: topic ?? this.topic,
      members: members ?? this.members,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  factory Channel.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members =
        memberList.map((i) => ChannelMember.fromJson(i)).toList();

    return Channel(
      networkId: json['network_id'] as int? ?? 0,
      name: json['name'] as String? ?? '',
      topic: json['topic'] as String? ?? '',
      members: members,
      isConnected: json['is_connected'] as bool? ?? false, // Parse is_connected
    );
  }

  /// Converts a Channel instance to a JSON map for persistence.
  Map<String, dynamic> toJson() {
    return {
      'network_id': networkId,
      'name': name,
      'topic': topic,
      'members': members.map((m) => m.toJson()).toList(),
      'is_connected': isConnected,
    };
  }
}