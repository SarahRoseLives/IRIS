import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/firebase_options.dart';
import 'package:iris/main_layout.dart';
import 'package:iris/screens/login_screen.dart';
import 'package:iris/services/encryption_service.dart';
import 'package:iris/services/notification_service.dart';
import 'package:iris/services/update_service.dart';
import 'package:iris/services/websocket_service.dart';
import 'package:iris/utils/web_check.dart'; // ✅ Platform-safe import
import 'package:iris/viewmodels/chat_state.dart';
import 'package:iris/widgets/fingerprint_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PendingNotification {
  static String? channelToNavigateTo;
  static Map<String, dynamic>? messageData;
}

final getIt = GetIt.instance;

void setupLocator() {
  if (!getIt.isRegistered<FlutterLocalNotificationsPlugin>()) {
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
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  setupLocator();
  final notificationService = getIt<NotificationService>();
  await notificationService.setupLocalNotifications();
  print("Handling a background message: ${message.messageId}");

  if (message.data['type'] == 'private_message') {
    final prefs = await SharedPreferences.getInstance();
    final pendingMessages = prefs.getStringList('pending_dm_messages') ?? [];
    pendingMessages.add(json.encode(message.data));
    await prefs.setStringList('pending_dm_messages', pendingMessages);
  }
  notificationService.showFlutterNotification(message);
}

@pragma('vm:entry-point')
void onDidReceiveNotificationResponse(
    NotificationResponse notificationResponse) async {
  final String? payload = notificationResponse.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = jsonDecode(payload);
      NotificationService().handleNotificationTap(data);
    } catch (e) {
      print("Error in onDidReceiveNotificationResponse: $e");
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (isFirebaseMessagingSupported()) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } else {
    print('[Firebase Messaging] Skipped: unsupported web environment');
  }

  setupLocator();

  await getIt<EncryptionService>().initialize();
  await getIt<NotificationService>().init();

  if (isFirebaseMessagingSupported()) {
    try {
      await FirebaseMessaging.instance.requestPermission();
      final token = await FirebaseMessaging.instance.getToken();
      print('[Firebase Messaging] Token: $token');
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
      navigatorKey: AuthWrapper.globalKey,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF5865F2),
        ),
      ),
      home: FingerprintGate(
        child: AuthWrapper(),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AuthWrapper extends StatefulWidget {
  static final GlobalKey<NavigatorState> globalKey = GlobalKey<NavigatorState>();
  static final GlobalKey<_AuthWrapperState> stateKey =
      GlobalKey<_AuthWrapperState>();

  AuthWrapper() : super(key: stateKey);

  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    stateKey.currentState
        ?.logoutAndShowLogin(showExpiredMessage: showExpiredMessage);
  }

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isLoggedIn = false; // PATCH: Add explicit login state tracking

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

    if (state == AppLifecycleState.resumed) {
      // Check if session is still valid
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      if (token == null) {
        AuthWrapper.forceLogout();
      }
    }
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (mounted && token != null && username != null) {
      setState(() {
        _isLoggedIn = true;
      });
      // Use globalKey for navigation to prevent stale context
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AuthWrapper.globalKey.currentState?.pushReplacement(
          MaterialPageRoute(
            builder: (_) => IrisLayout(username: username, token: token),
          ),
        );
      });
    } else {
      setState(() {
        _isLoading = false;
        _isLoggedIn = false;
      });
    }
  }

  Future<void> _checkForUpdates() async {
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      await UpdateService.checkForUpdates(context);
    }
  }

  // --- UPDATED logoutAndShowLogin ---
  Future<void> logoutAndShowLogin({bool showExpiredMessage = false}) async {
    print('[Auth] Beginning logout process...');

    try {
      // Disconnect WebSocket
      if (getIt.isRegistered<WebSocketService>()) {
        print('[Auth] Disconnecting WebSocket...');
        getIt<WebSocketService>().disconnect();
      }

      // Reset Encryption Service State
      if (getIt.isRegistered<EncryptionService>()) {
        print('[Auth] Resetting encryption state...');
        getIt<EncryptionService>().reset();
      }

      // Reset Chat State
      if (getIt.isRegistered<ChatState>()) {
        print('[Auth] Resetting chat state...');
        getIt<ChatState>().reset();
      }

      // Clear all persisted data for a clean logout
      final prefs = await SharedPreferences.getInstance();
      print('[Auth] Clearing all SharedPreferences...');
      await prefs.clear();

      // PATCH: Always update state
      setState(() {
        _isLoading = false;
        _isLoggedIn = false;
      });

      // PATCH: Use globalKey's Navigator for all navigation
      final navigator = AuthWrapper.globalKey.currentState;
      if (navigator != null && mounted) {
        print('[Auth] Navigating to LoginScreen...');
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => LoginScreen(showExpiredMessage: showExpiredMessage)),
          (route) => false,
        );
      } else {
        print('[Auth] Could not navigate to LoginScreen. Navigator or mounted state is invalid.');
        // PATCH: Fallback to forcing rebuild and showing login
        setState(() {
          _isLoading = false;
          _isLoggedIn = false;
        });
      }
    } catch (e) {
      print('[Auth] Error during logout: $e');
      // PATCH: Fallback
      setState(() {
        _isLoading = false;
        _isLoggedIn = false;
      });
    }
  }
  // --- END OF CHANGE ---

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

    // PATCH: Show login screen if not logged in
    if (!_isLoggedIn) {
      return LoginScreen(showExpiredMessage: false);
    }

    // PATCH: If logged in, show a placeholder until navigation completes
    return const Scaffold(
      backgroundColor: Color(0xFF313338),
      body: Center(
        child: CircularProgressIndicator(color: Color(0xFF5865F2)),
      ),
    );
  }
}