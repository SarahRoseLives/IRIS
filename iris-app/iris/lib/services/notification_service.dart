// lib/services/notification_service.dart
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/main.dart'; // To access AuthWrapper.globalKey
import 'package:iris/viewmodels/main_layout_viewmodel.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

// Note: The background handler is now a top-level function in main.dart

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

  // A single init method to be called from main()
  Future<void> init() async {
    // 1. REQUEST PERMISSION FOR ANDROID 13+
    final status = await Permission.notification.request();
    if (status.isGranted) {
      print("Notification permission granted.");
    } else {
      print("Notification permission denied.");
    }

    // This is all that's needed in this method for local notifications setup
    await setupLocalNotifications();

    // Set up listeners for different message states
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Got a message whilst in the foreground!');
      showFlutterNotification(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('A new onMessageOpenedApp event was published!');
      handleNotificationTap(message.data);
    });

    _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('App opened from terminated state by a notification!');
        handleNotificationTap(message.data);
      }
    });
  }

  // Can be called from main() or the background isolate
  Future<void> setupLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();

    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    // The onDidReceiveNotificationResponse is now passed in main.dart
    await _flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onDidReceiveNotificationResponse,
    );
  }


  Future<String?> getFCMToken() async {
    try {
      final token = await _firebaseMessaging.getToken();
      print("FCM Token: $token");
      return token;
    } catch (e) {
      print("Failed to get FCM token: $e");
      return null;
    }
  }

  // This method is now called by the foreground listener AND the background handler
  void showFlutterNotification(RemoteMessage message) {
    final String? title = message.data['title'];
    final String? body = message.data['body'];

    if (title != null && body != null) {
      _flutterLocalNotificationsPlugin.show(
        message.hashCode,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'iris_channel_id', // MUST MATCH the ID in AndroidManifest.xml
            'IRIS Messages',
            channelDescription: 'Notifications for new IRIS chat messages.',
            icon: '@mipmap/ic_launcher',
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        // Encode the full data payload to handle taps correctly
        payload: jsonEncode(message.data),
      );
    }
  }

  // Handles navigation when a notification is tapped, regardless of app state
  void handleNotificationTap(Map<String, dynamic> data) {
    // This uses the navigatorKey from main.dart to get a valid context
    final BuildContext? context = AuthWrapper.globalKey.currentContext;

    if (context != null && context.mounted) {
      final String? sender = data['sender'];
      final String channelName = (data['type'] == 'private_message' && sender != null)
          ? '@$sender'
          : data['channel_name'] ?? '';

      if (channelName.isNotEmpty) {
        print("Handling notification tap for channel: $channelName");
        try {
          // Use Provider to find the ViewModel and navigate
          final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
          viewModel.handleNotificationTap(channelName, "0"); // "0" is a placeholder messageId
        } catch (e) {
          print("Could not find MainLayoutViewModel to handle notification tap: $e");
        }
      }
    }
  }
}