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
import 'package:iris/controllers/chat_state.dart';
import 'package:iris/controllers/chat_controller.dart';

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
  // Only register FlutterLocalNotificationsPlugin if it's a supported platform.
  // This avoids issues on desktop/Linux where the plugin might not be configured.
  if ((kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) &&
      !getIt.isRegistered<FlutterLocalNotificationsPlugin>()) {
    getIt.registerSingleton<FlutterLocalNotificationsPlugin>(
        FlutterLocalNotificationsPlugin());
  }

  // Register NotificationService early, but its internal init will handle platform specifics.
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
  // Do NOT register ChatController here, because it requires username and token!
  // It will be registered in AuthWrapper's _checkLoginStatus.
}

class AuthManager {
  static Future<void> forceLogout({bool showExpiredMessage = false}) async {
    print('[AuthManager] Beginning force logout process...');
    try {
      // Safely dispose and unregister ChatController if it exists
      if (getIt.isRegistered<ChatController>()) {
        final chatController = getIt<ChatController>();
        chatController.dispose();
        getIt.unregister<ChatController>();
      }

      // Safely access WebSocketService if registered
      if (getIt.isRegistered<WebSocketService>()) {
        getIt<WebSocketService>().disconnect();
      }
      if (getIt.isRegistered<EncryptionService>()) {
        getIt<EncryptionService>().reset();
      }
      if (getIt.isRegistered<ChatState>()) {
        getIt<ChatState>().clearAllMessages();
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      final navigator = navigatorKey.currentState;
      if (navigator != null && navigator.mounted) {
        print('[AuthManager] Navigating to LoginScreen...');
        navigator.pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => LoginScreen(
              showExpiredMessage: showExpiredMessage,
              // START OF FIX: This callback is now corrected.
              onLoginSuccess: () {
                // After a successful login, the app state needs to be
                // re-initialized from the root. We replace the current
                // view (LoginScreen) with a new AuthWrapper, which will
                // then detect the new token and show the main chat UI.
                navigatorKey.currentState?.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => AuthWrapper()),
                  (route) => false,
                );
              },
              // END OF FIX
            ),
          ),
          (route) => false,
        );
      } else {
        print('[AuthManager] Navigator not mounted, cannot navigate.');
      }
    } catch (e) {
      print('[AuthManager] Error during forceLogout: $e');
    }
  }
}

// Background handler for Firebase Messaging - only applicable for Android (and iOS if enabled)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Only run on Android or iOS where background message handling is supported and useful
  if (!(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) return;

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

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
    // Provide a valid callback, even if it's just a print statement for background
    onDidReceiveNotificationResponse: (response) { print('Background notification tapped (Android/iOS): ${response.payload}'); },
    onDidReceiveBackgroundNotificationResponse: (response) { print('Background notification tapped (Android/iOS): ${response.payload}'); },
  );

  // Create the notification channel conditionally (Android specific)
  if (defaultTargetPlatform == TargetPlatform.android) {
    final AndroidNotificationChannel channel = AndroidNotificationChannel(
      'iris_channel_id',
      'iris Messages',
      description: 'Notifications for new iris chat messages',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 250, 250, 250]),
      showBadge: true,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  print("Handling a background message: ${message.messageId}");

  if (message.data['type'] == 'private_message' || message.data.containsKey('channel_name')) {
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
    if (defaultTargetPlatform == TargetPlatform.android) {
      androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'iris_channel_id',
        'iris Messages',
        channelDescription: 'Notifications for new iris chat messages',
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
      // For iOS, Android properties might not be directly applicable but harmless.
      androidPlatformChannelSpecifics = AndroidNotificationDetails(
        'iris_channel_id',
        'iris Messages',
        channelDescription: 'Notifications for new iris chat messages',
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
      DateTime.now().millisecondsSinceEpoch.remainder(100000), // Unique ID for each notification
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

// Callback for when a notification is tapped (foreground or background)
@pragma('vm:entry-point')
void onDidReceiveNotificationResponse(
    NotificationResponse notificationResponse) async {
  // Ensure Flutter binding is initialized if this is a background/terminated state launch
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase app must be initialized for Firebase services
  if ((kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) && Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  // Setup GetIt locator if it hasn't been already (crucial for background handlers)
  if (!GetIt.instance.isRegistered<NotificationService>()) {
    setupLocator();
  }

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase only on supported platforms or if already running
  if ((kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) && Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  }

  setupLocator(); // Register GetIt dependencies

  await getIt<EncryptionService>().initialize(); // Initialize encryption service

  // Initialize notification service only on supported platforms
  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
    await getIt<NotificationService>().init();
    if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) { // For native platforms
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    }
  }

  runApp(const irisApp());
}

class irisApp extends StatelessWidget {
  const irisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iris',
      navigatorKey: navigatorKey,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF5865F2),
        ),
        // Add a global scaffoldMessengerKey to allow showing Snackbars from anywhere.
        // scaffoldMessengerKey: GlobalKey<ScaffoldMessengerState>(),
      ),
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
  ChatController? _chatControllerInstance; // Hold the instance here

  DateTime? _lastBackgroundTime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Call _checkLoginStatus initially
    _checkLoginStatus();
    _checkForUpdates();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chatControllerInstance?.dispose();
    if (getIt.isRegistered<ChatController>()) {
      getIt.unregister<ChatController>(); // Ensure unregister when wrapper disposes
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    print("[AuthWrapper] AppLifecycleState changed to: $state");

    if (state == AppLifecycleState.resumed && _isLoggedIn && _chatControllerInstance != null) {
      print("[AuthWrapper] App resumed, isLoggedIn: $_isLoggedIn");
      bool needsValidation = _lastBackgroundTime != null &&
          DateTime.now().difference(_lastBackgroundTime!) > const Duration(minutes: 5);

      if (needsValidation) {
        print("[AuthWrapper] Session validation required after 5 min+ background.");
        final isValid = await getIt<ApiService>().validateSession(); // Validate session first
        if (!mounted) return;

        if (!isValid) {
          print("[AuthWrapper] Session validation failed. Forcing logout.");
          AuthManager.forceLogout(showExpiredMessage: true);
          return; // IMPORTANT: Exit here if validation fails
        } else {
          print("[AuthWrapper] Session is still valid.");
          // ONLY call handleAppResumed if session is confirmed valid
          _chatControllerInstance?.handleAppResumed();
        }
      } else {
        // If no validation needed, just call handleAppResumed
        _chatControllerInstance?.handleAppResumed();
      }
    } else if (state == AppLifecycleState.paused) {
      print("[AuthWrapper] App paused.");
      _lastBackgroundTime = DateTime.now();
      _chatControllerInstance?.handleAppPaused();
    }
  }

  // --- START OF FIX ---
  Future<void> _checkLoginStatus() async {
    print("[AuthWrapper] Checking login status...");
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (token != null && username != null) {
      print("[AuthWrapper] Found token. Validating session...");
      GetIt.instance<ApiService>().setToken(token);
      final isValid = await GetIt.instance<ApiService>().validateSession();
      if (!mounted) return;

      if (isValid) {
        try {
          // Create and register ChatController if it doesn't exist.
          if (!getIt.isRegistered<ChatController>()) {
            _chatControllerInstance = ChatController(
              username: username,
              token: token,
              chatState: getIt<ChatState>(),
              isAppInBackground: () =>
                  WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed,
            );
            getIt.registerSingleton<ChatController>(_chatControllerInstance!);
          } else {
            _chatControllerInstance = getIt<ChatController>();
          }

          // Await the initialization. If it fails, the catch block will handle it.
          await _chatControllerInstance!.initialize();

          // If initialization is successful, THEN update the state to show the main UI.
          if (!mounted) return;
          setState(() {
            _isLoggedIn = true;
            _isLoading = false;
            _username = username;
            _token = token;
          });
        } catch (e) {
          print("[AuthWrapper] Initialization failed, forcing logout: $e");
          if (mounted) {
            AuthManager.forceLogout(showExpiredMessage: true);
          }
        }
      } else {
        print("[AuthWrapper] Session expired or invalid. Forcing logout.");
        if (mounted) {
          AuthManager.forceLogout(showExpiredMessage: true);
        }
      }
    } else {
      print("[AuthWrapper] No stored token. Displaying LoginScreen.");
      if (mounted) {
        setState(() {
          _isLoggedIn = false;
          _isLoading = false;
        });
        if (getIt.isRegistered<ChatController>()) {
          getIt<ChatController>().dispose();
          getIt.unregister<ChatController>();
        }
      }
    }
  }
  // --- END OF FIX ---

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

    // IMPORTANT: Only render irisLayout if ChatController is guaranteed to be initialized and set.
    if (_isLoggedIn && _username != null && _token != null && _chatControllerInstance != null) {
      return irisLayout(
        username: _username!,
        token: _token!,
        chatController: _chatControllerInstance!,
      );
    } else {
      // When not logged in, pass the onLoginSuccess callback to LoginScreen.
      // This callback will trigger a re-check of login status by AuthWrapper.
      return LoginScreen(
        onLoginSuccess: () {
          // Instead of _checkLoginStatus directly, let the Navigator pop
          // This will cause AuthWrapper to rebuild and re-evaluate its state.
          // The pop() is handled inside AuthManager.forceLogout if session expired,
          // otherwise it would be a normal Navigator.pop from LoginScreen upon success.
          _checkLoginStatus(); // Re-trigger the logic to switch to MainLayout
        },
      );
    }
  }
}