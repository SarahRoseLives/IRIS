import 'channel_member.dart'; // Ensure this is imported for NetworkChannelState
import 'dart:developer'; // Add this import at the top for `log` function

// Sub-model for channels associated with a network (from server's ListNetworks response)
class NetworkChannelState {
  final String name;
  final String topic;
  final List<ChannelMember> members;
  final DateTime lastUpdate;
  final bool isConnected; // Added to match Channel model for easier conversion

  NetworkChannelState({
    required this.name,
    required this.topic,
    required this.members,
    required this.lastUpdate,
    this.isConnected = false, // Default to false if not provided
  });

  // Add a copyWith method for NetworkChannelState for easier updates within IrcNetwork
  NetworkChannelState copyWith({
    String? name,
    String? topic,
    List<ChannelMember>? members,
    DateTime? lastUpdate,
    bool? isConnected,
  }) {
    return NetworkChannelState(
      name: name ?? this.name,
      topic: topic ?? this.topic,
      members: members ?? this.members,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  factory NetworkChannelState.fromJson(Map<String, dynamic> json) {
    var memberList = json['members'] as List? ?? [];
    List<ChannelMember> members =
        memberList.map((i) => ChannelMember.fromJson(i)).toList();
    return NetworkChannelState(
      name: json['name'] as String? ?? '',
      topic: json['topic'] as String? ?? '',
      members: members,
      lastUpdate: DateTime.tryParse(json['last_update'] as String? ?? '') ?? DateTime.now(),
      isConnected: json['is_connected'] as bool? ?? false, // Parse from JSON, default to false
    );
  }

  // Convert to JSON (optional, but good for saving state if needed)
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'topic': topic,
      'members': members.map((m) => m.toJson()).toList(),
      'last_update': lastUpdate.toIso8601String(),
      'is_connected': isConnected,
    };
  }
}

class IrcNetwork {
  final int id;
  final String networkName;
  final String hostname;
  final int port;
  final bool useSsl;
  final String? serverPassword; // Only for sending to backend
  final bool autoReconnect;
  final List<String> modules;
  final List<String> performCommands;
  final List<String> initialChannels;
  final String nickname;
  final String? altNickname;
  final String? ident;
  final String? realname;
  final String? quitMessage;
  final bool isConnected; // Live status from server (made final for copyWith)
  final List<NetworkChannelState> channels; // Channels on this network

  IrcNetwork({
    required this.id,
    required this.networkName,
    required this.hostname,
    required this.port,
    required this.useSsl,
    this.serverPassword,
    required this.autoReconnect,
    required this.modules,
    required this.performCommands,
    required this.initialChannels,
    required this.nickname,
    this.altNickname,
    this.ident,
    this.realname,
    this.quitMessage,
    this.isConnected = false,
    required this.channels,
  });

  // Add copyWith method for immutable updates
  IrcNetwork copyWith({
    int? id,
    String? networkName,
    String? hostname,
    int? port,
    bool? useSsl,
    String? serverPassword,
    bool? autoReconnect,
    List<String>? modules,
    List<String>? performCommands,
    List<String>? initialChannels,
    String? nickname,
    String? altNickname,
    String? ident,
    String? realname,
    String? quitMessage,
    bool? isConnected,
    List<NetworkChannelState>? channels,
  }) {
    return IrcNetwork(
      id: id ?? this.id,
      networkName: networkName ?? this.networkName,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      useSsl: useSsl ?? this.useSsl,
      serverPassword: serverPassword ?? this.serverPassword,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      modules: modules ?? this.modules,
      performCommands: performCommands ?? this.performCommands,
      initialChannels: initialChannels ?? this.initialChannels,
      nickname: nickname ?? this.nickname,
      altNickname: altNickname ?? this.altNickname,
      ident: ident ?? this.ident,
      realname: realname ?? this.realname,
      quitMessage: quitMessage ?? this.quitMessage,
      isConnected: isConnected ?? this.isConnected,
      channels: channels ?? this.channels,
    );
  }

  factory IrcNetwork.fromJson(Map<String, dynamic> json) {
    var initialChannelsList = (json['initial_channels'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    // Add this logging to see what 'modules' looks like before parsing
    log('DEBUG: IrcNetwork.fromJson - Raw modules JSON part: ${json['modules']} (Type: ${json['modules']?.runtimeType})');

    var modulesList = (json['modules'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    log('DEBUG: IrcNetwork.fromJson - Parsed modulesList: $modulesList');

    var performCommandsList = (json['perform_commands'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    // Parse nested channels
    List<NetworkChannelState> networkChannels = [];
    if (json.containsKey('channels') && json['channels'] is List) {
      networkChannels = (json['channels'] as List)
          .map((c) => NetworkChannelState.fromJson(c))
          .toList();
    }

    return IrcNetwork(
      id: json['id'] as int? ?? 0,
      networkName: json['network_name'] as String? ?? 'Unknown Network',
      hostname: json['hostname'] as String? ?? '',
      port: json['port'] as int? ?? 6667,
      useSsl: json['use_ssl'] as bool? ?? false,
      // server_password is not returned from API for security
      autoReconnect: json['auto_reconnect'] as bool? ?? false,
      modules: modulesList, // This assigns the parsed list
      performCommands: performCommandsList,
      initialChannels: initialChannelsList,
      nickname: json['nickname'] as String? ?? '',
      altNickname: json['alt_nickname'] as String?,
      ident: json['ident'] as String?,
      realname: json['realname'] as String?,
      quitMessage: json['quit_message'] as String?,
      isConnected: json['is_connected'] as bool? ?? false,
      channels: networkChannels,
    );
  }

  // To send to the backend (e.g., for Add/Update)
  Map<String, dynamic> toJson({bool includeId = false}) {
    final Map<String, dynamic> data = {
      'network_name': networkName,
      'hostname': hostname,
      'port': port,
      'use_ssl': useSsl,
      'auto_reconnect': autoReconnect,
      'modules': modules,
      'perform_commands': performCommands,
      'initial_channels': initialChannels,
      'nickname': nickname,
      'alt_nickname': altNickname,
      'ident': ident,
      'realname': realname,
      'quit_message': quitMessage,
    };
    if (serverPassword != null && serverPassword!.isNotEmpty) {
      data['server_password'] = serverPassword;
    }
    if (includeId) {
      data['id'] = id;
    }
    return data;
  }
}