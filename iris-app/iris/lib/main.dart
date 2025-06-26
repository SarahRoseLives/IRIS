import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:iris/firebase_options.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/services/notification_service.dart';
import 'package:iris/services/websocket_service.dart';
import 'services/encryption_service.dart';
import 'main_layout.dart';
import 'screens/login_screen.dart';
import 'package:iris/services/update_service.dart';

// Simple static class to hold a pending navigation action from a notification tap.
class PendingNotification {
  static String? channelToNavigateTo;
}

final getIt = GetIt.instance;

void setupLocator() {
  // Register FlutterLocalNotificationsPlugin if not already registered
  if (!getIt.isRegistered<FlutterLocalNotificationsPlugin>()) {
    getIt.registerSingleton<FlutterLocalNotificationsPlugin>(
        FlutterLocalNotificationsPlugin());
  }
  // Register NotificationService if not already registered
  if (!getIt.isRegistered<NotificationService>()) {
    getIt.registerSingleton<NotificationService>(NotificationService());
  }
  // Register WebSocketService if not already registered
  if (!getIt.isRegistered<WebSocketService>()) {
    getIt.registerSingleton<WebSocketService>(WebSocketService());
  }
  // Register EncryptionService if not already registered
  if (!getIt.isRegistered<EncryptionService>()) {
    getIt.registerSingleton<EncryptionService>(EncryptionService());
  }
}

// Entry point for background Firebase messages
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Ensure locators are set up for background isolate
  setupLocator();
  final notificationService = getIt<NotificationService>();
  await notificationService.setupLocalNotifications();
  print("Handling a background message: ${message.messageId}");
  notificationService.showFlutterNotification(message);
}

// Entry point for notification tap responses
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
  // Ensure Flutter engine is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // Set up background message handler for Firebase
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Set up all service locators
  setupLocator();

  // Initialize our custom services that depend on locators
  await getIt<EncryptionService>().initialize();
  await getIt<NotificationService>().init();

  // Run the app
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
      home: AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// AuthWrapper handles the initial logic of checking if a user is logged in.
class AuthWrapper extends StatefulWidget {
  static final GlobalKey<NavigatorState> globalKey = GlobalKey<NavigatorState>();
  static final GlobalKey<_AuthWrapperState> stateKey =
      GlobalKey<_AuthWrapperState>();

  AuthWrapper() : super(key: stateKey);

  // Global method to force logout from anywhere in the app
  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    stateKey.currentState?.logoutAndShowLogin(showExpiredMessage: showExpiredMessage);
  }

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
    _checkForUpdates();
  }

  // Check SharedPreferences for a stored token to decide where to navigate
  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (mounted && token != null && username != null) {
      // If token exists, go directly to the main layout
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => IrisLayout(username: username, token: token),
        ),
      );
    } else {
      // Otherwise, show the login screen
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Periodically check for app updates from GitHub
  Future<void> _checkForUpdates() async {
    // Add a small delay to not interfere with startup animations
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      await UpdateService.checkForUpdates(context);
    }
  }

  // Clear credentials and navigate back to the login screen
  Future<void> logoutAndShowLogin({bool showExpiredMessage = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');

    // Use the global navigator key to ensure we have a valid context
    if (AuthWrapper.globalKey.currentContext != null && mounted) {
      Navigator.of(AuthWrapper.globalKey.currentContext!).pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => LoginScreen(showExpiredMessage: showExpiredMessage)),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Show a loading spinner while checking login status
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF313338),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF5865F2)),
        ),
      );
    }
    // If not loading and not logged in, show the LoginScreen
    return LoginScreen(showExpiredMessage: false);
  }
}