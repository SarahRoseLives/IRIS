import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Firebase Imports
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:iris/firebase_options.dart';

import 'package:get_it/get_it.dart';
import 'package:iris/services/notification_service.dart';
import 'main_layout.dart';
import 'services/api_service.dart';
import 'models/login_response.dart';
import 'screens/login_screen.dart'; // <-- Moved LoginScreen import

import 'package:iris/services/update_service.dart'; // <--- update check

// Simple static class to hold a pending navigation action from a notification tap.
class PendingNotification {
  static String? channelToNavigateTo;
}

final getIt = GetIt.instance;

void setupLocator() {
  if (!getIt.isRegistered<FlutterLocalNotificationsPlugin>()) {
    getIt.registerSingleton<FlutterLocalNotificationsPlugin>(FlutterLocalNotificationsPlugin());
  }
  if (!getIt.isRegistered<NotificationService>()) {
    getIt.registerSingleton<NotificationService>(NotificationService());
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // We need to re-setup the locator for this separate isolate.
  setupLocator();

  final notificationService = getIt<NotificationService>();
  await notificationService.setupLocalNotifications();
  print("Handling a background message: ${message.messageId}");
  notificationService.showFlutterNotification(message);
}

@pragma('vm:entry-point')
void onDidReceiveNotificationResponse(NotificationResponse notificationResponse) async {
  final String? payload = notificationResponse.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = jsonDecode(payload);
      // Can't use GetIt here directly in a static context easily, so we create a new instance
      // and let it buffer the tap.
      NotificationService().handleNotificationTap(data);
    } catch (e) {
      print("Error in onDidReceiveNotificationResponse: $e");
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  setupLocator();

  await getIt<NotificationService>().init();

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

class AuthWrapper extends StatefulWidget {
  static final GlobalKey<NavigatorState> globalKey = GlobalKey<NavigatorState>();
  static final GlobalKey<_AuthWrapperState> stateKey = GlobalKey<_AuthWrapperState>();

  AuthWrapper() : super(key: stateKey);

  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    stateKey.currentState?.logoutAndShowLogin(showExpiredMessage: showExpiredMessage);
  }

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoading = true;
  bool _showExpiredMessage = false;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
    _checkForUpdates(); // <--- update check
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (mounted && token != null && username != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => IrisLayout(username: username, token: token),
        ),
      );
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // Add this method for update checking
  Future<void> _checkForUpdates() async { // <--- update check
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      await UpdateService.checkForUpdates(context);
    }
  }

  Future<void> logoutAndShowLogin({bool showExpiredMessage = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');

    if (mounted) {
      setState(() {
        _showExpiredMessage = showExpiredMessage;
      });
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginScreen(showExpiredMessage: _showExpiredMessage)),
        (route) => false,
      );
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
    return LoginScreen(showExpiredMessage: _showExpiredMessage);
  }
}