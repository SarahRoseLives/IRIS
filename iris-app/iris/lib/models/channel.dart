// lib/models/channel.dart

import 'channel_member.dart';

class Channel {
  final String name;
  List<ChannelMember> members; // Make it non-final to allow updates

  Channel({required this.name, required this.members});

  factory Channel.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members = memberList.map((i) => ChannelMember.fromJson(i)).toList();

    return Channel(
      name: json['name'] ?? '',
      members: members,
    );
  }
}