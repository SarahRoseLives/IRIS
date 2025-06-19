// lib/models/channel_member.dart

class ChannelMember {
  final String nick;
  final String prefix;

  ChannelMember({required this.nick, required this.prefix});

  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    return ChannelMember(
      nick: json['nick'] ?? '',
      prefix: json['prefix'] ?? '',
    );
  }
}