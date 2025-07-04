import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:iris/firebase_options.dart';
import 'package:iris/main_layout.dart';
import 'package:iris/screens/login_screen.dart';
import 'package:iris/services/api_service.dart';
import 'package:iris/services/encryption_service.dart';
import 'package:iris/services/update_service.dart';
import 'package:iris/services/websocket_service.dart';
import 'package:iris/utils/web_check.dart';
import 'package:iris/viewmodels/chat_state.dart';
// FingerprintGate import removed

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:iris/services/notification_service_platform.dart'
    show NotificationService;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final getIt = GetIt.instance;

class PendingNotification {
  static String? channelToNavigateTo;
  static Map<String, dynamic>? messageData;
}

void setupLocator() {
  if ((kIsWeb || defaultTargetPlatform == TargetPlatform.android) &&
      !getIt.isRegistered<FlutterLocalNotificationsPlugin>()) {
    getIt.registerSingleton<FlutterLocalNotificationsPlugin>(
        FlutterLocalNotificationsPlugin());
  }

  if (!getIt.isRegistered<NotificationService>()) {
    getIt.registerSingleton<NotificationService>(NotificationService());
  }

  if (!getIt.isRegistered<WebSocketService>()) {
    getIt.registerSingleton<WebSocketService>(WebSocketService());
  }
  if (!getIt.isRegistered<EncryptionService>()) {
    getIt.registerSingleton<EncryptionService>(EncryptionService());
  }
  if (!getIt.isRegistered<ChatState>()) {
    getIt.registerSingleton<ChatState>(ChatState());
  }
  if (!getIt.isRegistered<ApiService>()) {
    getIt.registerSingleton<ApiService>(ApiService());
  }
}

class AuthManager {
  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    print('[AuthManager] Beginning force logout process...');
    try {
      if (getIt.isRegistered<WebSocketService>()) {
        getIt<WebSocketService>().disconnect();
      }
      if (getIt.isRegistered<EncryptionService>()) {
        getIt<EncryptionService>().reset();
      }
      if (getIt.isRegistered<ChatState>()) {
        getIt<ChatState>().reset();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final navigator = navigatorKey.currentState;
      if (navigator != null) {
        print('[AuthManager] Navigating to LoginScreen...');
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) =>
                  LoginScreen(showExpiredMessage: showExpiredMessage)),
          (route) => false,
        );
      }
    } catch (e) {
      print('[AuthManager] Error during forceLogout: $e');
    }
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!(kIsWeb || defaultTargetPlatform == TargetPlatform.android)) return;
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

  // Android initialization
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings();
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );

  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
  );

  // Create the notification channel conditionally
  AndroidNotificationChannel channel;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    channel = AndroidNotificationChannel(
      'iris_channel_id',
      'IRIS Messages',
      description: 'Notifications for new IRIS chat messages',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 250, 250, 250]),
      showBadge: true,
    );
  } else {
    channel = AndroidNotificationChannel(
      'iris_channel_id',
      'IRIS Messages',
      description: 'Notifications for new IRIS chat messages',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      showBadge: true,
    );
  }

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  print("Handling a background message: ${message.messageId}");

  if (message.data['type'] == 'private_message') {
    final prefs = await SharedPreferences.getInstance();
    final pendingMessages = prefs.getStringList('pending_dm_messages') ?? [];
    pendingMessages.add(json.encode(message.data));
    await prefs.setStringList('pending_dm_messages', pendingMessages);
  }

  final notification = message.notification;
  final data = message.data;
  final String? title = notification?.title ?? data['title'];
  final String? body = notification?.body ?? data['body'];

  if (title != null && body != null) {
    AndroidNotificationDetails androidPlatformChannelSpecifics;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'iris_channel_id',
        'IRIS Messages',
        channelDescription: 'Notifications for new IRIS chat messages',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 250, 250, 250]),
        icon: '@mipmap/ic_launcher',
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
        styleInformation: BigTextStyleInformation(body),
      );
    } else {
      androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'iris_channel_id',
        'IRIS Messages',
        channelDescription: 'Notifications for new IRIS chat messages',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
        styleInformation: BigTextStyleInformation(body),
      );
    }

    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      NotificationDetails(
        android: androidPlatformChannelSpecifics,
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }
}

@pragma('vm:entry-point')
void onDidReceiveNotificationResponse(
    NotificationResponse notificationResponse) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }
  setupLocator();

  final String? payload = notificationResponse.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = jsonDecode(payload);
      getIt<NotificationService>().handleNotificationTap(data);
    } catch (e) {
      print("Error in onDidReceiveNotificationResponse: $e");
    }
  }
}

// _maybeFingerprintGate function removed

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  setupLocator();

  await getIt<EncryptionService>().initialize();

  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
    await getIt<NotificationService>().init();
    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      print('[Firebase Messaging] Token: $token');
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    } catch (e) {
      print('[Firebase Messaging] Error: $e');
    }
  }

  runApp(const IRISApp());
}

class IRISApp extends StatelessWidget {
  const IRISApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IRIS',
      navigatorKey: navigatorKey,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF5865F2),
        ),
      ),
      // The FingerprintGate is removed from here.
      home: AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AuthWrapper extends StatefulWidget {
  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  String? _username;
  String? _token;

  DateTime? _lastBackgroundTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLoginStatus();
    _checkForUpdates();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && _isLoggedIn) {
      if (_lastBackgroundTime != null &&
          DateTime.now().difference(_lastBackgroundTime!) >
              Duration(minutes: 5)) {
        final isValid = await getIt<ApiService>().validateSession();
        if (!isValid) {
          AuthManager.forceLogout(showExpiredMessage: true);
        }
      }
      _lastBackgroundTime = null;
    } else if (state == AppLifecycleState.paused) {
      _lastBackgroundTime = DateTime.now();
    }
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (mounted) {
      if (token != null && username != null) {
        // ---> FIX: Set the token on the singleton ApiService <---
        GetIt.instance<ApiService>().setToken(token);

        setState(() {
          _isLoggedIn = true;
          _isLoading = false;
          _username = username;
          _token = token;
        });
      } else {
        setState(() {
          _isLoggedIn = false;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _checkForUpdates() async {
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      await UpdateService.checkForUpdates(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF313338),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF5865F2)),
        ),
      );
    }

    if (_isLoggedIn && _username != null && _token != null) {
      return IrisLayout(username: _username!, token: _token!);
    } else {
      return LoginScreen();
    }
  }
}