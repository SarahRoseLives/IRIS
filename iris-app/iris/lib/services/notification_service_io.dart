import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:iris/main.dart'; // To access PendingNotification and the global onDidReceiveNotificationResponse
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;

/// Service for handling notifications. It is safe to instantiate on any platform,
/// but will only perform operations on supported platforms (Android and Web).
class NotificationService {
  FirebaseMessaging? _firebaseMessaging;
  FlutterLocalNotificationsPlugin? _flutterLocalNotificationsPlugin;

  final bool _isSupported = kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  NotificationService();

  static String? Function()? getCurrentDMChannel;

  Future<void> init() async {
    if (!_isSupported) {
      print("[NotificationService] Skipping initialization: unsupported platform.");
      return;
    }

    _firebaseMessaging = FirebaseMessaging.instance;
    _flutterLocalNotificationsPlugin = GetIt.instance<FlutterLocalNotificationsPlugin>();

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

    _firebaseMessaging?.getInitialMessage().then((RemoteMessage? message) {
      if (message != null) {
        print('[NotificationService] App opened from terminated state by a notification!');
        handleNotificationTap(message.data);
      }
    });

    final fcmToken = await getFCMToken();
    if (fcmToken != null) {
      print("[NotificationService] FCM Token: $fcmToken");
    }
  }

  /// Sets up the channels and settings for flutter_local_notifications.
  Future<void> setupLocalNotifications() async {
    if (!_isSupported || _flutterLocalNotificationsPlugin == null) return;

    // For Android 8.0+, creating a channel is required to show any notification.
    // --- Begin: Delete and recreate channel to ensure updated sound settings ---
    final androidPlugin = _flutterLocalNotificationsPlugin!
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      try {
        await androidPlugin.deleteNotificationChannel('iris_channel_id');
        print('[NotificationService] Deleted existing notification channel to ensure proper sound settings.');
      } catch (e) {
        print('[NotificationService] Could not delete notification channel: $e');
      }
    }
    // --- End: Delete and recreate channel ---

    final AndroidNotificationChannel channel = AndroidNotificationChannel(
      'iris_channel_id', // id
      'IRIS Messages', // title
      description: 'Notifications for new IRIS chat messages', // description
      importance: Importance.high, // Changed from max to high for better compatibility
      playSound: true,
      // sound: RawResourceAndroidNotificationSound('notification'), // REMOVED
      enableVibration: true,
      // --- FIX: Conditionally set vibrationPattern to null on web ---
      vibrationPattern: kIsWeb ? null : Int64List.fromList([0, 250, 250, 250]),
      showBadge: true,
    );

    await _flutterLocalNotificationsPlugin!
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings initializationSettingsIOS = DarwinInitializationSettings();
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await _flutterLocalNotificationsPlugin!.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onDidReceiveNotificationResponse,
    );
  }

  /// Shows a local notification from simple data, used for WebSocket messages.
  void showSimpleNotification({
    required String title,
    required String body,
    required Map<String, dynamic> payload,
  }) {
    if (!_isSupported || _flutterLocalNotificationsPlugin == null) return;

    final String? channelName = payload['channel_name'];

    // Suppress notification if user is currently viewing the relevant DM.
    if (channelName != null &&
        getCurrentDMChannel != null &&
        getCurrentDMChannel!()?.toLowerCase() == channelName.toLowerCase()) {
      print('[NotificationService] Suppressing notification for active DM: $channelName');
      return;
    }

    print('[NotificationService] Showing notification with Title: "$title" and Body: "$body"');
    _flutterLocalNotificationsPlugin!.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000), // Unique ID
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'iris_channel_id',
          'IRIS Messages',
          channelDescription: 'Notifications for new IRIS chat messages',
          importance: Importance.high,
          priority: Priority.high,
          color: const Color(0xFF5865F2),
          playSound: true,
          // sound: const RawResourceAndroidNotificationSound('notification'), // REMOVED
          enableVibration: true,
          // --- FIX: Conditionally set vibrationPattern to null on web ---
          vibrationPattern: kIsWeb ? null : Int64List.fromList([0, 250, 250, 250]),
          icon: '@mipmap/ic_launcher',
          largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(payload),
    );
  }

  /// Displays a local notification from an FCM RemoteMessage.
  void showFlutterNotification(RemoteMessage message) {
    print('[NotificationService] Received FCM message. Data: ${message.data}. Notification: ${message.notification?.toMap()}');

    final String? finalTitle = message.data['title'] ?? message.notification?.title;
    final String? finalBody = message.data['body'] ?? message.notification?.body;

    if (finalTitle != null && finalBody != null) {
      showSimpleNotification(
        title: finalTitle,
        body: finalBody,
        payload: message.data,
      );
    } else {
      print('[NotificationService] Could not find title or body in FCM message. Notification will not be shown.');
    }
  }

  /// Buffers notification data for the UI to handle when it's ready.
  void handleNotificationTap(Map<String, dynamic> data) async {
    final String? sender = data['sender'];
    final String? channelNameData = data['channel_name'];
    final String? type = data['type'];
    String channelName = '';

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

    PendingNotification.messageData = {
      'sender': sender ?? 'Unknown',
      'body': data['body'] ?? '',
      'message': data['message'] ?? '',
      'content': data['content'] ?? '',
      'time': data['time'] ?? DateTime.now().toIso8601String(),
      'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
    };
  }

  /// Retrieves the Firebase Cloud Messaging (FCM) token for this device.
  Future<String?> getFCMToken() async {
    if (!_isSupported) {
      return null;
    }
    try {
      _firebaseMessaging ??= FirebaseMessaging.instance;
      return await _firebaseMessaging!.getToken();
    } catch (e) {
      print("[NotificationService] Failed to get FCM token: $e");
      return null;
    }
  }
}