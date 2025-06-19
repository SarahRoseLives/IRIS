// lib/main.dart
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';

// Firebase Imports
import 'package:firebase_core/firebase_core.dart';
import 'package:iris/firebase_options.dart';
import 'package:iris/services/notification_service.dart';

import 'main_layout.dart';
import 'services/api_service.dart';
import 'models/login_response.dart';
import 'viewmodels/main_layout_viewmodel.dart';

// ** NEW: Use a service locator pattern like get_it for easier access to singletons **
// This avoids passing the instance around everywhere.
import 'package:get_it/get_it.dart';

final getIt = GetIt.instance;

void setupLocator() {
  getIt.registerSingleton<FlutterLocalNotificationsPlugin>(FlutterLocalNotificationsPlugin());
  getIt.registerSingleton<NotificationService>(NotificationService());
}
// ** END NEW **

// This callback is for flutter_local_notifications when a notification is tapped
@pragma('vm:entry-point')
void onDidReceiveNotificationResponse(NotificationResponse notificationResponse) async {
  final String? payload = notificationResponse.payload;
  if (payload != null) {
    try {
      final Map<String, dynamic> data = jsonDecode(payload);
      final notificationService = getIt<NotificationService>();
      notificationService.handleNotificationTap(data);
    } catch (e) {
      print("Error in onDidReceiveNotificationResponse: $e");
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ** NEW: Initialize Firebase **
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // ** NEW: Setup service locators **
  setupLocator();

  // ** NEW: Initialize Notification Service **
  await getIt<NotificationService>().init();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');

  final DarwinInitializationSettings initializationSettingsDarwin =
      DarwinInitializationSettings();

  final InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsDarwin,
  );

  // Initialize flutter_local_notifications
  await getIt<FlutterLocalNotificationsPlugin>().initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
    onDidReceiveBackgroundNotificationResponse: onDidReceiveNotificationResponse,
  );

  runApp(const IRISApp());
}

class IRISApp extends StatelessWidget {
  const IRISApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IRIS',
      // The navigatorKey allows us to access the context from anywhere
      navigatorKey: AuthWrapper.globalKey,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF5865F2),
          secondary: Color(0xFF5865F2),
        ),
      ),
      // AuthWrapper now uses the static key directly
      home: AuthWrapper(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// AuthWrapper now uses a GlobalKey<NavigatorState> for navigation context
class AuthWrapper extends StatefulWidget {
  // Use a NavigatorState key to get context from anywhere
  static final GlobalKey<NavigatorState> globalKey = GlobalKey<NavigatorState>();

  // A separate key for the state if needed, though NavigatorState is more useful
  static final GlobalKey<_AuthWrapperState> stateKey = GlobalKey<_AuthWrapperState>();

  AuthWrapper() : super(key: stateKey);

  static Future<void> forceLogout() async {
    stateKey.currentState?.logoutAndShowLogin();
  }

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

// ... rest of AuthWrapper and LoginScreen remain the same ...
// No changes are needed in the rest of the file.
class _AuthWrapperState extends State<AuthWrapper> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final username = prefs.getString('username');

    if (token != null && username != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Pass username and token to IrisLayout
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => IrisLayout(username: username, token: token), // Pass token here
          ),
        );
      });
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> logoutAndShowLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('username');

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
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
    return const LoginScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _loading = false;
  String? _message;
  final ApiService _apiService = ApiService();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      final LoginResponse response = await _apiService.login(
        _usernameController.text.trim(),
        _passwordController.text,
      );

      if (response.success && response.token != null) {
        final token = response.token!;
        final username = _usernameController.text.trim();

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', token);
        await prefs.setString('username', username);

        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => IrisLayout(username: username, token: token), // Pass token here
            ),
          );
        }
      } else {
        setState(() {
          _message = response.message;
        });
      }
    } catch (e) {
      setState(() {
        _message = "Error: $e";
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF313338),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 370,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF2B2D31),
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black,
                  blurRadius: 30,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'IRIS',
                    style: TextStyle(
                      fontFamily: 'Montserrat',
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF5865F2),
                      letterSpacing: 2,
                      shadows: [
                        Shadow(
                          blurRadius: 12,
                          color: Color(0xFF5865F2),
                          offset: Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 30),
                  TextFormField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF232428),
                      labelText: 'Username',
                      prefixIcon: const Icon(Icons.person, color: Color(0xFF5865F2)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty ? 'Enter username' : null,
                    enabled: !_loading,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _passwordController,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF232428),
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock, color: Color(0xFF5865F2)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    validator: (value) => value == null || value.isEmpty ? 'Enter password' : null,
                    obscureText: true,
                    enabled: !_loading,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5865F2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      icon: const Icon(Icons.login, color: Colors.white),
                      label: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Text('Login', style: TextStyle(color: Colors.white)),
                      onPressed: _loading
                          ? null
                          : () {
                              if (_formKey.currentState!.validate()) {
                                _login();
                              }
                            },
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 20),
                    Text(
                      _message!,
                      style: TextStyle(
                        color: _message!.contains("success") ? Colors.green : Colors.redAccent,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
