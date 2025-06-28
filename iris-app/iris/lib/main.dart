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
import 'package:iris/viewmodels/chat_state.dart';
import 'widgets/fingerprint_gate.dart';
import 'utils/web_check.dart'; // ✅ Platform-safe import

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

  Future<void> _checkForUpdates() async {
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) {
      await UpdateService.checkForUpdates(context);
    }
  }

  Future<void> logoutAndShowLogin({bool showExpiredMessage = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');

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
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF313338),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF5865F2)),
        ),
      );
    }
    return LoginScreen(showExpiredMessage: false);
  }
}
