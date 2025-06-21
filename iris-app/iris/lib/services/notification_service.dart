// lib/services/notification_service.dart

import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/main.dart'; // To access AuthWrapper.globalKey and PendingNotification
import 'package:iris/viewmodels/main_layout_viewmodel.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

  // ... init() and setupLocalNotifications() are unchanged ...
  Future<void> init() async {
    final status = await Permission.notification.request();
    if (status.isGranted) {
      print("[NotificationService] Notification permission granted.");
    } else {
      print("[NotificationService] Notification permission denied.");
    }
    await setupLocalNotifications();
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('[NotificationService] Got a message whilst in the foreground!');
      showFlutterNotification(message);
    });
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('[NotificationService] A new onMessageOpenedApp event was published!');
      handleNotificationTap(message.data);
    });
    _firebaseMessaging.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('[NotificationService] App opened from terminated state by a notification!');
        handleNotificationTap(message.data);
      }
    });
    final fcmToken = await _firebaseMessaging.getToken();
    if (fcmToken != null) {
      print("[NotificationService] FCM Token: $fcmToken");
    }
  }

  Future<void> setupLocalNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );
    await _flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onDidReceiveNotificationResponse,
    );
  }

  void showFlutterNotification(RemoteMessage message) {
    print('[NotificationService] showFlutterNotification: Received message with data: ${message.data}');
    final String? title = message.data['title'];
    final String? body = message.data['body'];
    if (title != null && body != null) {
      _flutterLocalNotificationsPlugin.show(
        message.hashCode,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'iris_channel_id',
            'IRIS Messages',
            channelDescription: 'Notifications for new IRIS chat messages',
            icon: '@mipmap/ic_launcher',
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
        payload: jsonEncode(message.data),
      );
    } else {
      print('[NotificationService] Received push message but title or body was missing in the data payload.');
    }
  }

  /// Handles the user tapping on a notification.
  /// If the app is fully running, it navigates immediately.
  /// Otherwise, it buffers the channel name for the ViewModel to handle later.
  void handleNotificationTap(Map<String, dynamic> data) {
    final String? sender = data['sender'];
    final String channelName = (data['type'] == 'private_message' && sender != null)
        ? '@$sender'
        : data['channel_name'] ?? '';

    if (channelName.isEmpty) return;

    final BuildContext? context = AuthWrapper.globalKey.currentContext;

    // Check if the app's UI is ready and the ViewModel is available
    if (context != null && context.mounted) {
      try {
        final viewModel = Provider.of<MainLayoutViewModel>(context, listen: false);
        print("[NotificationService] App context is ready. Handling tap immediately for channel: $channelName");
        viewModel.handleNotificationTap(channelName, "0");
        PendingNotification.channelToNavigateTo = null; // Clear any stale pending request
        return;
      } catch (e) {
        // This can happen if the context is available but the Provider is not yet in the widget tree.
        // We'll fall through to the buffering logic below.
        print("[NotificationService] Could not find ViewModel, buffering notification tap: $e");
      }
    }

    // If the context wasn't ready or the ViewModel couldn't be found, buffer the navigation action.
    print("[NotificationService] App context not ready. Buffering notification tap for channel: $channelName");
    PendingNotification.channelToNavigateTo = channelName;
  }

  // ... getFCMToken() is unchanged ...
  Future<String?> getFCMToken() async {
    try {
      final token = await _firebaseMessaging.getToken();
      return token;
    } catch (e) {
      print("[NotificationService] Failed to get FCM token: $e");
      return null;
    }
  }
}