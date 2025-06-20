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
import '../main.dart';
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

  List<String> get publicChannelNames =>
      _channels.where((c) => c.name.startsWith('#')).map((c) => c.name).toList();

  List<String> get dmChannelNames =>
      _channels.where((c) => c.name.startsWith('@')).map((c) => c.name).toList();

  String get selectedConversationTarget {
    if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
      return _channels[_selectedChannelIndex].name;
    }
    return _loadingChannels ? "Connecting..." : "No channels";
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

  // --- CONSTRUCTOR & INITIALIZATION ---
  MainLayoutViewModel({required this.username, String? initialToken}) {
    _token = initialToken;
    _apiService = ApiService(_token!);
    _webSocketService = WebSocketService();

    WidgetsBinding.instance.addObserver(this);

    _listenToWebSocketStatus();
    _listenToInitialState();
    _listenToWebSocketChannels();
    _listenToWebSocketMessages();
    _listenToMembersUpdate();
    _listenToWebSocketErrors();

    if (_token != null) {
      _connectWebSocket();
      _loadAvatarForUser(username);
      _initNotifications();
      _loadPersistedMessages();
    } else {
      _handleLogout();
    }
  }

  // --- IMAGE ATTACHMENT UPLOAD ---
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

        // Add the message to local display immediately
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

        // Then send via WebSocket
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

  // --- WEBSOCKET LISTENERS ---

  void _listenToInitialState() {
    _webSocketService.initialStateStream.listen((payload) {
      final channelsPayload = payload['channels'] as Map<String, dynamic>;
      final usersPayload = payload['users'] as Map<String, dynamic>;

      // Preserve existing messages for channels we already have
      final Map<String, List<Message>> preservedMessages = {};
      for (final entry in _channelMessages.entries) {
        preservedMessages[entry.key] = List<Message>.from(entry.value);
      }

      _channels.clear();
      _channelMessages.clear();

      channelsPayload.forEach((channelName, channelData) {
        final channel = Channel.fromJson(channelData as Map<String, dynamic>);
        _channels.add(channel);

        final key = channel.name.toLowerCase();
        _channelMessages[key] = preservedMessages[key] ?? channel.messages;

        for (var member in channel.members) {
          _loadAvatarForUser(member.nick);
        }
        for (var message in channel.messages) {
          _loadAvatarForUser(message.from);
        }
      });

      usersPayload.forEach((username, avatarUrl) {
        if (avatarUrl != null && avatarUrl is String) {
          _userAvatars[username] = avatarUrl;
        }
      });

      _channels.sort((a, b) => a.name.compareTo(b.name));

      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }

      _loadingChannels = false;
      _channelError = null;
      notifyListeners();
      _scrollToBottom();

      _persistMessages();
    });
  }

  void _listenToWebSocketStatus() {
    _webSocketService.statusStream.listen((status) {
      _wsStatus = status;
      if (status == WebSocketStatus.unauthorized) {
        _handleLogout();
      }
      notifyListeners();
    });
  }

  void _listenToWebSocketChannels() {
    _webSocketService.channelsStream.listen((channels) async {
      await _fetchChannelsList();
    });
  }

  void _listenToWebSocketMessages() {
    _webSocketService.messageStream.listen((message) {
      String channelName = (message['channel_name'] ?? '').toLowerCase();
      final String sender = message['sender'] ?? 'Unknown';
      final bool isPrivateMessage = !channelName.startsWith('#');

      String conversationTarget;
      if (isPrivateMessage) {
        final String conversationPartner = (sender.toLowerCase() == username.toLowerCase()) ? channelName : sender;
        conversationTarget = '@$conversationPartner';
        if (_channels.indexWhere((c) => c.name.toLowerCase() == conversationTarget.toLowerCase()) == -1) {
          _channels.add(Channel(name: conversationTarget, members: [], messages: []));
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
      });

      _addMessageToDisplay(conversationTarget.toLowerCase(), newMessage);
      _loadAvatarForUser(sender);
      notifyListeners();

      _persistMessages();
    });
  }

  void _listenToMembersUpdate() {
    _webSocketService.membersUpdateStream.listen((update) {
      final String channelName = update['channel_name'];
      final List<ChannelMember> newMembers = update['members'];
      try {
        final channel = _channels.firstWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
        channel.members = newMembers;
        notifyListeners();
      } catch (e) {
        print("Received member update for an unknown channel: $channelName");
      }
    });
  }

  void _listenToWebSocketErrors() {
    _webSocketService.errorStream.listen((error) {
      print("[ViewModel] WebSocket Error: $error");
    });
  }

  // --- DATA FETCHING & STATE MANAGEMENT ---

  Future<void> _fetchChannelsList() async {
    _loadingChannels = true;
    notifyListeners();
    try {
      final freshChannels = await _apiService.fetchChannels();
      _channels = freshChannels;
      if (_selectedChannelIndex >= _channels.length) {
        _selectedChannelIndex = 0;
      }
      _channelError = null;
    } catch (e) {
      _channelError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _loadingChannels = false;
      notifyListeners();
    }
  }

  void _addMessageToDisplay(String channelNameKey, Message newMessage) {
    final key = channelNameKey.toLowerCase();
    _channelMessages.putIfAbsent(key, () => []);
    // Only add if message doesn't already exist
    if (!_channelMessages[key]!.any((m) => m.id == newMessage.id)) {
      _channelMessages[key]!.add(newMessage);
      _scrollToBottom();
      notifyListeners();
      _persistMessages();
    }
  }

  // --- USER ACTIONS ---

  void onChannelSelected(String channelName) => _selectConversation(channelName);
  void onDmSelected(String dmChannelName) => _selectConversation(dmChannelName);

  void _selectConversation(String conversationName) {
    final index = _channels.indexWhere((c) => c.name.toLowerCase() == conversationName.toLowerCase());
    if (index != -1) {
      _selectedChannelIndex = index;
      _scrollToBottom();
      notifyListeners();
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
    String target = currentConversation.startsWith('@') ? currentConversation.substring(1) : currentConversation;

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
      _addInfoMessageToCurrentChannel('Failed to send message: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void handleNotificationTap(String channelName, String messageId) {
    if (channelName.startsWith('@') && _channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase()) == -1) {
      _channels.add(Channel(name: channelName, members: [], messages: []));
      _channels.sort((a, b) => a.name.compareTo(b.name));
    }
    final int targetIndex = _channels.indexWhere((c) => c.name.toLowerCase() == channelName.toLowerCase());
    if (targetIndex != -1) {
      _selectedChannelIndex = targetIndex;
      _showLeftDrawer = false;
      _showRightDrawer = false;
      notifyListeners();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }
  }

  // --- HELPER & LIFECYCLE METHODS ---

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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
    if (_token != null && (_wsStatus == WebSocketStatus.disconnected || _wsStatus == WebSocketStatus.error)) {
      _webSocketService.connect(_token!);
    }
  }

  void toggleLeftDrawer() {
    _showLeftDrawer = !_showLeftDrawer;
    if(_showLeftDrawer) _showRightDrawer = false;
    notifyListeners();
  }

  void toggleRightDrawer() {
    _showRightDrawer = !_showRightDrawer;
    if(_showRightDrawer) _showLeftDrawer = false;
    notifyListeners();
  }

  Future<void> _handleLogout() async {
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
    if (username.isEmpty || _userAvatars.containsKey(username)) return;

    _userAvatars[username] = '';

    final List<String> possibleExtensions = ['.png', '.jpg', '.jpeg', '.gif'];
    String? foundUrl;

    for (final ext in possibleExtensions) {
      final String potentialAvatarUrl = 'http://$apiHost:$apiPort/avatars/$username$ext';
      try {
        final response = await http.head(Uri.parse(potentialAvatarUrl));
        if (response.statusCode == 200) {
          foundUrl = potentialAvatarUrl;
          break;
        }
      } catch (e) {
      }
    }
    if (foundUrl != null) {
      _userAvatars[username] = foundUrl;
    }
    notifyListeners();
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
    String currentChannelName = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex].name
        : '';
    try {
      switch (command) {
        case 'join':
          if (args.isEmpty || !args.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /join <#channel_name>');
          } else {
            await _apiService.joinChannel(args);
            await _fetchChannelsList();
            _selectConversation(args);
          }
          break;
        case 'part':
          String channelToPart = args.isNotEmpty ? args : currentChannelName;
          if (channelToPart.isEmpty || !channelToPart.startsWith('#')) {
            _addInfoMessageToCurrentChannel('Usage: /part [#channel_name]');
          } else {
            await _apiService.partChannel(channelToPart);
            await _fetchChannelsList();
          }
          break;
        default:
          _addInfoMessageToCurrentChannel('Unknown command: /$command. Type /help for a list of commands.');
      }
    } catch (e) {
      _addInfoMessageToCurrentChannel('Failed to execute /$command: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _initNotifications() async {
    final notificationService = GetIt.instance<NotificationService>();
    final fcmToken = await notificationService.getFCMToken();
    if (fcmToken != null) {
      await _apiService.registerFCMToken(fcmToken);
    }
  }

  // --- MESSAGE PERSISTENCE ---

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
          final messageList = (messages as List).map((m) => Message.fromJson(m)).toList();
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
    _webSocketService.dispose();
    super.dispose();
  }
}