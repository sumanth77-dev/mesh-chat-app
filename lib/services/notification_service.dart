// ============================================================
// FILE: lib/services/notification_service.dart
// PURPOSE: Show local notifications for incoming mesh messages.
//
// Works fully OFFLINE — no internet required.
// Uses flutter_local_notifications package.
// ============================================================

import 'dart:ui' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';

class NotificationService {
  // Singleton so the same instance is used across the app
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Android notification channel details
  static const String _channelId = 'relayx_messages';
  static const String _channelName = 'Mesh Messages';
  static const String _channelDesc = 'Incoming messages from the RelayX mesh network';

  // -----------------------------------------------------------
  // initialize()
  // Call this once in main() before runApp().
  // Sets up the notification channel and asks for permission.
  // -----------------------------------------------------------
  Future<void> initialize() async {
    // Android initialization settings
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');

    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(initSettings);

    // Create the notification channel (required on Android 8+)
    const androidChannel = AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: _channelDesc,
      importance: Importance.high,  // Heads-up notification
      playSound: true,
      enableVibration: true,
    );

    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    debugPrint('🔔 [NotificationService] Initialized');
  }

  // -----------------------------------------------------------
  // requestPermission()
  // Required on Android 13+ (API 33+) to show notifications.
  // Safe to call on older Android — it just returns true.
  // -----------------------------------------------------------
  Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    debugPrint('🔔 [NotificationService] Permission granted: $granted');
  }

  // -----------------------------------------------------------
  // showMessageNotification()
  // Shows a heads-up notification for an incoming mesh message.
  //
  // Parameters:
  //   senderName — the display name of the sender
  //   messageText — the decrypted message content
  // -----------------------------------------------------------
  Future<void> showMessageNotification({
    required String senderName,
    required String messageText,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFF6C63FF), // RelayX purple accent
      // Heads-up style — shows on top even when app is open
      fullScreenIntent: false,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    // Use a hash of the sender name as a stable notification ID
    // so messages from the same person update instead of stacking
    final notifId = senderName.hashCode.abs() % 10000;

    await _plugin.show(
      notifId,
      senderName,         // Notification title = sender name
      messageText,        // Notification body = message content
      notificationDetails,
    );

    debugPrint('🔔 [NotificationService] Showed notification from $senderName');
  }
}
