import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/firebase_options.dart';
import 'package:iris/main_layout.dart';
import 'package:iris/screens/login_screen.dart';
import 'package:iris/services/api_service.dart'; // Import ApiService for the exception
import 'package:iris/services/encryption_service.dart';
import 'package:iris/services/notification_service.dart';
import 'package:iris/services/update_service.dart';
import 'package:iris/services/websocket_service.dart';
import 'package:iris/utils/web_check.dart'; // ✅ Platform-safe import
import 'package:iris/viewmodels/chat_state.dart';
import 'package:iris/widgets/fingerprint_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- CHANGE 1: Define navigatorKey and GetIt instance at the top level ---
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
final getIt = GetIt.instance;


class PendingNotification {
  static String? channelToNavigateTo;
  static Map<String, dynamic>? messageData;
}

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
  // Register ApiService if not already registered
  if (!getIt.isRegistered<ApiService>()) {
    getIt.registerSingleton<ApiService>(ApiService());
  }
}

// --- CHANGE 2: Create a dedicated AuthManager class for logout logic ---
class AuthManager {
  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    print('[AuthManager] Beginning force logout process...');

    try {
      // Disconnect services
      if (getIt.isRegistered<WebSocketService>()) {
        getIt<WebSocketService>().disconnect();
      }
      if (getIt.isRegistered<EncryptionService>()) {
        getIt<EncryptionService>().reset();
      }
      if (getIt.isRegistered<ChatState>()) {
        getIt<ChatState>().reset();
      }

      // Clear all persisted data for a clean logout
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Use the global navigatorKey to navigate to the LoginScreen
      final navigator = navigatorKey.currentState;
      if (navigator != null) {
        print('[AuthManager] Navigating to LoginScreen...');
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => LoginScreen(showExpiredMessage: showExpiredMessage)),
          (route) => false, // This predicate removes all routes from the stack
        );
      }
    } catch (e) {
      print('[AuthManager] Error during forceLogout: $e');
    }
  }
}


@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // ... (no changes needed here)
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
  // ... (no changes needed here)
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
  // ... (no changes needed here)
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
      // --- CHANGE 3: Use the top-level navigatorKey ---
      navigatorKey: navigatorKey,
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


// --- CHANGE 4: AuthWrapper is now a simpler stateful widget ---
class AuthWrapper extends StatefulWidget {
  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  String? _username;
  String? _token;

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
      // When app resumes, validate the session with the server
      final isValid = await getIt<ApiService>().validateSession();
      if (!isValid) {
        // Use the new global logout manager
        AuthManager.forceLogout(showExpiredMessage: true);
      }
    }
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (mounted) {
      if (token != null && username != null) {
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

    // This build method is now declarative. It builds the UI based on state
    // without performing navigation as a side-effect.
    if (_isLoggedIn && _username != null && _token != null) {
      return IrisLayout(username: _username!, token: _token!);
    } else {
      return LoginScreen();
    }
  }
}