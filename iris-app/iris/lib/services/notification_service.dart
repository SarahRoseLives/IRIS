// lib/services/notification_service.dart

import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/main.dart'; // To access PendingNotification
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  final FirebaseMessaging _firebaseMessaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

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

  /// REFACTORED: This method no longer tries to access the ViewModel directly.
  /// It now *always* buffers the tap action using the PendingNotification static class.
  /// The ChatController is responsible for checking this buffer upon initialization.
  void handleNotificationTap(Map<String, dynamic> data) {
    final String? sender = data['sender'];
    final String channelName = (data['type'] == 'private_message' && sender != null)
        ? '@$sender'
        : data['channel_name'] ?? '';

    if (channelName.isEmpty) return;

    // Always buffer the navigation action. This is simpler and more robust.
    print("[NotificationService] Buffering notification tap for channel: $channelName");
    PendingNotification.channelToNavigateTo = channelName;
  }

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