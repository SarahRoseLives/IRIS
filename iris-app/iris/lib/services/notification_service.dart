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

  // Static callback to get the currently viewed DM (set by MainLayoutViewModel)
  static String? Function()? getCurrentDMChannel;

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
    final String? sender = message.data['sender'];
    final String? channelName = message.data['channel_name'];
    final String? type = message.data['type'];

    // Robust DM suppression: suppress if viewing the DM, whether 'sender' or 'channel_name' matches
    String? possibleDm;
    if (type == "private_message" && sender != null) {
      possibleDm = '@$sender';
    }
    // If channelName is provided and is not a public channel, treat as DM
    if (channelName != null && !channelName.startsWith('#')) {
      possibleDm = '@$channelName';
    }

    if (possibleDm != null &&
        getCurrentDMChannel != null &&
        getCurrentDMChannel!()?.toLowerCase() == possibleDm.toLowerCase()) {
      print('[NotificationService] Suppressing notification for active DM: $possibleDm');
      return;
    }

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

  /// Buffer both navigation and message data for later handling in ChatController.
  void handleNotificationTap(Map<String, dynamic> data) async {
    final String? sender = data['sender'];
    final String? channelNameData = data['channel_name'];
    final String? type = data['type'];
    String channelName = '';

    // Prefer proper DM naming
    if (type == 'private_message' && sender != null) {
      channelName = '@$sender';
    } else if (channelNameData != null && !channelNameData.startsWith('#')) {
      channelName = '@$channelNameData';
    } else {
      channelName = channelNameData ?? '';
    }
    if (channelName.isEmpty) return;

    print("[NotificationService] Buffering notification tap for channel: $channelName");
    PendingNotification.channelToNavigateTo = channelName;

    // Store the message data (ensure both 'body' and 'message' are available for fallback)
    PendingNotification.messageData = {
      'sender': sender ?? 'Unknown',
      'body': data['body'] ?? '',
      'message': data['message'] ?? '',
      'content': data['content'] ?? '',
      'time': data['time'] ?? DateTime.now().toIso8601String(),
      'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
    };
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