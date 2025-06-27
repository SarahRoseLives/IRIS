class ChannelMember {
  final String nick;
  final String prefix;
  final bool isAway; // ADDED

  ChannelMember({
    required this.nick,
    required this.prefix,
    this.isAway = false, // ADDED with default
  });

  factory ChannelMember.fromJson(Map<String, dynamic> json) {
    return ChannelMember(
      nick: json['nick'] ?? '',
      prefix: json['prefix'] ?? '',
      isAway: json['is_away'] ?? false, // ADDED: expects backend to send 'is_away'
    );
  }

  // START OF CHANGE
  /// Converts a ChannelMember instance to a JSON map for persistence.
  Map<String, dynamic> toJson() => {
        'nick': nick,
        'prefix': prefix,
        'is_away': isAway,
      };
  // END OF CHANGE
}