import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:iris/services/notification_service.dart';
import 'package:get_it/get_it.dart';

import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../main.dart' show AuthWrapper, PendingNotification;
import '../config.dart';
import '../models/channel.dart';
import '../models/channel_member.dart';

class MainLayoutViewModel extends ChangeNotifier with WidgetsBindingObserver {
  final String username;
  late ApiService _apiService;
  late WebSocketService _webSocketService;

  int _selectedChannelIndex = 0;
  bool _showLeftDrawer = false;
  bool _showRightDrawer = false;
  bool _loadingChannels = true;
  String? _channelError;
  String? _token;
  final Map<String, List<Message>> _channelMessages = {};
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<Channel> _channels = [];
  WebSocketStatus _wsStatus = WebSocketStatus.disconnected;
  final Map<String, String> _userAvatars = {};
  bool _isAppFocused = true;
  bool unjoinedChannelsExpanded = false;

  // --- GETTERS ---
  int get selectedChannelIndex => _selectedChannelIndex;
  bool get showLeftDrawer => _showLeftDrawer;
  bool get showRightDrawer => _showRightDrawer;
  bool get loadingChannels => _loadingChannels;
  String? get channelError => _channelError;
  String? get token => _token;
  TextEditingController get msgController => _msgController;
  ScrollController get scrollController => _scrollController;
  WebSocketStatus get wsStatus => _wsStatus;
  Map<String, String> get userAvatars => _userAvatars;
  List<String> get joinedPublicChannelNames =>
      _channels
          .where((c) => c.name.startsWith('#') && c.members.isNotEmpty)
          .map((c) => c.name)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  List<String> get unjoinedPublicChannelNames =>
      _channels
          .where((c) => c.name.startsWith('#') && c.members.isEmpty)
          .map((c) => c.name)
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  List<String> get dmChannelNames =>
      _channels.where((c) => c.name.startsWith('@')).map((c) => c.name).toList();
  String get selectedConversationTarget {
    if (_loadingChannels) return "Initializing...";
    if (_wsStatus != WebSocketStatus.connected) {
      return _wsStatus == WebSocketStatus.connecting
          ? "Connecting..."
          : "Disconnected";
    }
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].name;
    }
    return _channels.isNotEmpty ? _channels[0].name : "No channels";
  }
  List<ChannelMember> get members {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].members;
    }
    return [];
  }
  List<Message> get currentChannelMessages {
    final target = selectedConversationTarget.toLowerCase();
    return _channelMessages[target] ?? [];
  }

  MainLayoutViewModel({required this.username, String? initialToken}) {
    _token = initialToken;
    _apiService = ApiService(_token!);
    _webSocketService = GetIt.instance<WebSocketService>(); // <-- FIXED: Use singleton

    WidgetsBinding.instance.addObserver(this);

    // Setup all listeners
    _listenToWebSocketStatus();
    _listenToInitialState();
    _listenToWebSocketMessages();
    _listenToMembersUpdate();
    _listenToWebSocketErrors();

    if (_token != null) {
      _initializeSession();
    } else {
      _handleLogout();
    }
  }

  // Centralized method for session initialization.
  Future<void> _initializeSession() async {
    _loadingChannels = true;
    notifyListeners();

    await _loadPersistedMessages();
    _loadAvatarForUser(username);

    _connectWebSocket();

    _initNotifications();
    _handlePendingNotification();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print("AppLifecycleState changed: $state");
    _isAppFocused = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused) {
      _persistMessages();
    } else if (state == AppLifecycleState.resumed) {
      _connectWebSocket();
    }
  }

  void _connectWebSocket() {
    if (_token != null &&
        (_wsStatus == WebSocketStatus.disconnected ||
            _wsStatus == WebSocketStatus.error)) {
      print("[ViewModel] App resumed or disconnected, attempting to connect WebSocket.");
      _loadingChannels = true;
      notifyListeners();
      _webSocketService.connect(_token!);
    }
  }

  // This is now the single source of truth for initial channel/member data.
  void _listenToInitialState() {
    _webSocketService.initialStateStream.listen((payload) {
      print("[ViewModel] Received initial_state payload from WebSocket.");
      final channelsPayload = payload['channels'] as Map<String, dynamic>?;

      _channels.clear();

      if (channelsPayload != null) {
        channelsPayload.forEach((channelName, channelData) {
          final channel = Channel.fromJson(channelData as Map<String, dynamic>);
          _channels.add(channel);
          for (var member in channel.members) {
            _loadAvatarForUser(member.nick);
          }
        });
      }

      _loadAvatarForUser(username);
      _channels.sort((a, b) => a.name.compareTo(b.name));

      // Ensure selected index is valid
      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }

      // Select the first public channel by default if one exists
      final firstPublicChannelIndex =
          _channels.indexWhere((c) => c.name.startsWith('#'));
      if (firstPublicChannelIndex != -1) {
        _selectedChannelIndex = firstPublicChannelIndex;
      }

      _loadingChannels = false;
      _channelError = null;
      notifyListeners();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }).onError((e) {
      _channelError = "Error receiving initial state: $e";
      _loadingChannels = false;
      notifyListeners();
    });
  }

  void _listenToWebSocketStatus() {
    _webSocketService.statusStream.listen((status) {
      _wsStatus = status;
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
      if (status != WebSocketStatus.connected &&
          status != WebSocketStatus.connecting) {
        _loadingChannels = false;
      }
      notifyListeners();
    });
  }

  Future<void> partChannel(String channelName) async {
    if (!channelName.startsWith('#')) {
      _addInfoMessageToCurrentChannel('You can only part public channels');
      return;
    }

    try {
      await _apiService.partChannel(channelName);
      // The websocket 'channel_part' event should be the source of truth now.
      // We manually remove the channel from the local list for a faster UI update.
      final initialIndex = _selectedChannelIndex;
      _channels.removeWhere(
          (c) => c.name.toLowerCase() == channelName.toLowerCase());
      if (selectedConversationTarget == channelName ||
          initialIndex >= _channels.length) {
        _selectedChannelIndex =
            _channels.indexWhere((c) => c.name.startsWith("#"));
        if (_selectedChannelIndex == -1) _selectedChannelIndex = 0;
      }
      notifyListeners();
    } catch (e) {
      _addInfoMessageToCurrentChannel(
          'Failed to leave channel: ${e.toString()}');
    }
  }

  void _handlePendingNotification() {
    if (PendingNotification.channelToNavigateTo != null) {
      final channelName = PendingNotification.channelToNavigateTo!;
      print(
          '[ViewModel] Handling buffered notification tap for channel: $channelName');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handleNotificationTap(channelName, "0");
        PendingNotification.channelToNavigateTo = null;
      });
    }
  }

  void handleNotificationTap(String channelName, String messageId) {
    if (channelName.startsWith('@') &&
        _channels.indexWhere(
                (c) => c.name.toLowerCase() == channelName.toLowerCase()) ==
            -1) {
      _channels.add(Channel(name: channelName, members: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }

    final int targetIndex = _channels
        .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());

    if (targetIndex != -1) {
      _selectedChannelIndex = targetIndex;
      _showLeftDrawer = false;
      _showRightDrawer = false;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    } else {
      print(
          '[ViewModel] Could not find channel "$channelName" to navigate to.');
    }
  }

  Future<void> uploadAttachment(String filePath) async {
    print('[ViewModel] Starting attachment upload from $filePath');
    try {
      final file = File(filePath);
      final fileName = file.path.split('/').last;
      final mimeType = _getMimeType(fileName);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://$apiHost:$apiPort/api/upload-attachment'),
      );
      request.headers['Authorization'] = 'Bearer $_token';
      request.files.add(await http.MultipartFile.fromPath(
        'file',
        file.path,
        contentType: mimeType != null ? MediaType.parse(mimeType) : null,
      ));

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseBody);

      if (response.statusCode == 200 && jsonResponse['success'] == true) {
        final imageUrl = jsonResponse['url'];
        final fullImageUrl = 'http://$apiHost:$apiPort$imageUrl';
        final currentConversation = selectedConversationTarget;
        final sentMessage = Message(
          from: username,
          content: fullImageUrl,
          time: DateTime.now(),
          id: DateTime.now().millisecondsSinceEpoch.toString(),
        );
        _addMessageToDisplay(currentConversation.toLowerCase(), sentMessage);
        print('[ViewModel] Added local message with URL: $fullImageUrl');
        notifyListeners();
        final target = currentConversation.startsWith('@')
            ? currentConversation.substring(1)
            : currentConversation;
        _webSocketService.sendMessage(target, fullImageUrl);
        print('[ViewModel] Sent attachment via WebSocket to $target');
      } else {
        _addInfoMessageToCurrentChannel(
            'Failed to upload attachment: ${jsonResponse['message'] ?? 'Unknown error'}');
      }
    } catch (e) {
      _addInfoMessageToCurrentChannel('Attachment upload failed: $e');
    }
  }

  String? _getMimeType(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      default:
        return null;
    }
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';
      final bool isPrivateMessage = !channelName.startsWith('#');
      final bool isHistory = message['is_history'] ?? false;
      String conversationTarget;
      if (isPrivateMessage) {
        final String conversationPartner =
            (sender.toLowerCase() == username.toLowerCase())
                ? channelName
                : sender;
        conversationTarget = '@$conversationPartner';
        if (_channels.indexWhere(
                (c) =>
                    c.name.toLowerCase() == conversationTarget.toLowerCase()) ==
            -1) {
          _channels.add(Channel(name: conversationTarget, members: []));
          _channels.sort((a, b) => a.name.compareTo(b.name));
        }
      } else {
        conversationTarget = channelName;
      }
      final newMessage = Message.fromJson({
        'from': sender,
        'content': message['text'] ?? '',
        'time': message['time'] ?? DateTime.now().toIso8601String(),
        'id': message['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        'isHistorical': isHistory,
      });
      if (isHistory) {
        _prependMessageToDisplay(conversationTarget.toLowerCase(), newMessage);
      } else {
        _addMessageToDisplay(conversationTarget.toLowerCase(), newMessage);
      }
      _loadAvatarForUser(sender);
      notifyListeners();
      _persistMessages();
    });
  }

  void _prependMessageToDisplay(String channelNameKey, Message newMessage) {
    final key = channelNameKey.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);
    if (!_channelMessages[key]!.any((m) => m.id == newMessage.id)) {
      _channelMessages[key]!.insert(0, newMessage);
      notifyListeners();
      _persistMessages();
    }
  }

  void _addMessageToDisplay(String channelNameKey, Message newMessage) {
    final key = channelNameKey.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);
    if (!_channelMessages[key]!.any((m) => m.id == newMessage.id)) {
      _channelMessages[key]!.add(newMessage);
      _scrollToBottom();
      notifyListeners();
      _persistMessages();
    }
  }

  void _listenToMembersUpdate() {
    _webSocketService.membersUpdateStream.listen((update) {
      final String channelName = update['channel_name'];
      final List<dynamic> membersRaw = update['members'];
      final List<ChannelMember> newMembers = membersRaw
          .map((m) => m is ChannelMember ? m : ChannelMember.fromJson(m))
          .toList();

      final channelIndex = _channels
          .indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
      if (channelIndex != -1) {
        _channels[channelIndex].members = newMembers;

        if (selectedConversationTarget.toLowerCase() ==
            channelName.toLowerCase()) {
          notifyListeners();
        } else {
          notifyListeners();
        }
        for (var member in newMembers) {
          _loadAvatarForUser(member.nick);
        }
      } else {
        print("Received member update for an unknown channel: $channelName");
      }
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      print("[ViewModel] WebSocket Error: $error");
      _channelError = error;
      notifyListeners();
    });
  }

  Future<void> loadChannelHistory(String channelName, {int limit = 100}) async {
    if (!channelName.startsWith('#')) return;
    try {
      final response = await http.get(
        Uri.parse(
            'http://$apiHost:$apiPort/api/history/${Uri.encodeComponent(channelName)}?limit=$limit'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          final List<dynamic> history = data['history'] ?? [];
          final messages = history
              .map((item) => Message(
                    from: item['sender'] ?? 'Unknown',
                    content: item['text'] ?? '',
                    time: DateTime.tryParse(item['timestamp'] ?? '')
                            ?.toLocal() ??
                        DateTime.now(),
                    id: 'hist-${item['timestamp']}-${item['sender']}',
                    isHistorical: true,
                  ))
              .toList();
          final key = channelName.toLowerCase();
          _channelMessages.putIfAbsent(key, () => []);
          _channelMessages[key]!.insertAll(0, messages);
          final senders = messages.map((m) => m.from).toSet();
          for (final sender in senders) {
            _loadAvatarForUser(sender);
          }
          notifyListeners();
          _persistMessages();
        }
      }
    } catch (e) {
      print('Error loading channel history: $e');
    }
  }

  void onChannelSelected(String channelName) => _selectConversation(channelName);

  void onUnjoinedChannelTap(String channelName) async {
    try {
      await _apiService.joinChannel(channelName);
      // The websocket 'channel_join' event should be the source of truth.
      // We can add the channel manually for a faster UI update.
      if (!_channels.any(
          (c) => c.name.toLowerCase() == channelName.toLowerCase())) {
        _channels.add(Channel(name: channelName, members: [])); // Add a placeholder
        _channels.sort((a, b) => a.name.compareTo(b.name));
      }
      _selectConversation(channelName);
    } catch (e) {
      _addInfoMessageToCurrentChannel('Failed to join channel: $channelName');
    }
  }

  void onDmSelected(String dmChannelName) => _selectConversation(dmChannelName);

  void _selectConversation(String conversationName) {
    final index = _channels
        .indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;
      _scrollToBottom();
      notifyListeners();
      if (conversationName.startsWith('#')) {
        loadChannelHistory(conversationName);
      }
    }
  }

  Future<void> handleSendMessage() async {
    final text = _msgController.text.trim();
    if (text.isEmpty || _token == null) return;
    _msgController.clear();
    if (text.startsWith('/')) {
      await _handleCommand(text);
      return;
    }
    final currentConversation = selectedConversationTarget;
    String target = currentConversation.startsWith('@')
        ? currentConversation.substring(1)
        : currentConversation;
    final sentMessage = Message(
      from: username,
      content: text,
      time: DateTime.now(),
      id: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    _addMessageToDisplay(currentConversation.toLowerCase(), sentMessage);
    try {
      _webSocketService.sendMessage(target, text);
    } catch (e) {
      _addInfoMessageToCurrentChannel(
          'Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void toggleUnjoinedChannelsExpanded() {
    unjoinedChannelsExpanded = !unjoinedChannelsExpanded;
    notifyListeners();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients &&
          _scrollController.position.maxScrollExtent > 0) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void toggleLeftDrawer() {
    _showLeftDrawer = !_showLeftDrawer;
    if (_showLeftDrawer) _showRightDrawer = false;
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    if (_showRightDrawer) _showLeftDrawer = false;
    notifyListeners();
  }

  Future<void> _handleLogout() async {
    _webSocketService.dispose(); // Close WebSocket connection on logout.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');
    AuthWrapper.forceLogout();
  }

  void selectMainView() {
    final index = _channels.indexWhere((c) => c.name.startsWith('#'));
    if (index != -1) {
      _selectedChannelIndex = index;
    } else if (_channels.isNotEmpty) {
      _selectedChannelIndex = 0;
    }
    notifyListeners();
  }

  Future<void> _loadAvatarForUser(String username) async {
    if (username.isEmpty ||
        (_userAvatars.containsKey(username) &&
            _userAvatars[username]!.isNotEmpty)) return;

    _userAvatars[username] = ''; // Placeholder to prevent re-fetching

    final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
    String? foundUrl;
    for (final ext in possibleExtensions) {
      final String potentialAvatarUrl =
          'http://$apiHost:$apiPort/avatars/$username$ext';
      try {
        final response = await http.head(Uri.parse(potentialAvatarUrl));
        if (response.statusCode == 200) {
          foundUrl = potentialAvatarUrl;
          break;
        }
      } catch (e) {
        // Errors are expected for non-existent files, so we can ignore them.
      }
    }
    if (foundUrl != null) {
      _userAvatars[username] = foundUrl;
      notifyListeners();
    }
  }

  void _addInfoMessageToCurrentChannel(String message) {
    final currentChannel = selectedConversationTarget;
    final infoMessage = Message(
        from: 'IRIS Bot',
        content: message,
        time: DateTime.now(),
        id: DateTime.now().millisecondsSinceEpoch.toString());
    _addMessageToDisplay(currentChannel.toLowerCase(), infoMessage);
  }

  Future<void> _handleCommand(String commandText) async {
    final parts = commandText.substring(1).split(' ');
    final command = parts[0].toLowerCase();
    final args = parts.skip(1).join(' ').trim();
    String currentChannelName =
        _channels.isNotEmpty && _selectedChannelIndex < _channels.length
            ? _channels[_selectedChannelIndex].name
            : '';
    try {
      switch (command) {
        case 'join':
          if (args.isEmpty || !args.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /join <#channel_name>');
          } else {
            onUnjoinedChannelTap(args);
          }
          break;
        case 'part':
          String channelToPart = args.isNotEmpty ? args : currentChannelName;
          if (channelToPart.isEmpty || !channelToPart.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /part [#channel_name]');
          } else {
            partChannel(channelToPart);
          }
          break;
        default:
          _addInfoMessageToCurrentChannel('Unknown command: /$command.');
      }
    } catch (e) {
      _addInfoMessageToCurrentChannel(
          'Failed to execute /$command: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _initNotifications() async {
    final notificationService = GetIt.instance<NotificationService>();
    final fcmToken = await notificationService.getFCMToken();
    if (fcmToken != null) {
      await _apiService.registerFCMToken(fcmToken);
    }
  }

  Future<void> _persistMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesToSave = <String, dynamic>{};
    _channelMessages.forEach((channel, messages) {
      messagesToSave[channel] = messages.map((m) => m.toMap()).toList();
    });
    await prefs.setString('cached_messages', json.encode(messagesToSave));
  }

  Future<void> _loadPersistedMessages() async {
    final prefs = await SharedPreferences.getInstance();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _msgController.dispose();
    _scrollController.dispose();
    // Do not dispose of the WebSocketService here.
    // It should persist across hot restarts and be explicitly
    // disposed of only on logout to prevent stream closures.
    super.dispose();
  }
}