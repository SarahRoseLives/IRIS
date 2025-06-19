// lib/services/notification_service.dart
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/firebase_options.dart';
import 'package:iris/main.dart'; // To access the global navigatorKey
import 'package:iris/viewmodels/main_layout_viewmodel.dart'; // To call methods
import 'package:provider/provider.dart';

// This handler must be a top-level function (not a class method)
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  print("Handling a background message: ${message.messageId}");

  // Since this is a background isolate, we create a new instance to show the notification
  final notificationService = NotificationService();
  await notificationService.setupLocalNotifications(); // Ensure local notifications are setup
  notificationService.showFlutterNotification(message);
}

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

  // A new setup method for local notifications to be called from the background isolate
  Future<void> setupLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );
    await _flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> init() async {
    await _firebaseMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('Got a message whilst in the foreground!');
      showFlutterNotification(message);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('A new onMessageOpenedApp event was published!');
      // ** FIX: Call the now-public method **
      handleNotificationTap(message.data);
    });

    _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('App opened from terminated state by a notification!');
        // ** FIX: Call the now-public method **
        handleNotificationTap(message.data);
      }
    });
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

  void showFlutterNotification(RemoteMessage message) {
    // The Go backend sends a data-only payload, so we use the fields from `message.data`
    final String? title = message.data['title'];
    final String? body = message.data['body'];

    if (title != null && body != null) {
      _flutterLocalNotificationsPlugin.show(
        message.hashCode,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'iris_channel_id',
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
        payload: jsonEncode(message.data),
      );
    }
  }

  // ** FIX: Method is now public (no leading underscore) **
  void handleNotificationTap(Map<String, dynamic> data) {
    final BuildContext? context = AuthWrapper.globalKey.currentContext;
    if (context != null && context.mounted) {
      final String? sender = data['sender'];
      // The gateway sends private messages with the recipient's name as the "channel"
      final String channelName = (data['type'] == 'private_message' && sender != null)
          ? '@$sender'
          : data['channel_name'] ?? '';

      if (channelName.isNotEmpty) {
        print("Handling notification tap for channel: $channelName");
        // Use the Provider to find the MainLayoutViewModel and call the navigation method
        try {
          final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
          // Navigate and let the view model handle the rest
          viewModel.handleNotificationTap(channelName, "0");
        } catch (e) {
          print("Could not find MainLayoutViewModel to handle notification tap: $e");
        }
      }
    }
  }
}