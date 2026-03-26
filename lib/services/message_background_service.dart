import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/json_string_sanitize.dart';

const String _backgroundTaskName = 'lomhor.message.background.poll';
const String _backgroundTaskUniqueName = 'lomhor.message.background.unique';

@pragma('vm:entry-point')
void messageBackgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    await MessageBackgroundService.ensureInitialized(forBackground: true);
    await MessageBackgroundService.pollAndNotify(allowWhenForeground: false);
    return true;
  });
}

class MessageBackgroundService {
  MessageBackgroundService._();

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'lomhor_new_messages',
    'New messages',
    description: 'Alerts when a new LoRa message is received.',
    importance: Importance.high,
  );

  static Timer? _foregroundTimer;
  static bool _initialized = false;
  static bool _isAppInForeground = true;
  static bool _isPollingNow = false;

  static Future<void> ensureInitialized({bool forBackground = false}) async {
    if (!_initialized) {
      await _initializeNotifications();
      _initialized = true;
    }

    if (!forBackground) {
      await _registerBackgroundPollingTask();
      _startForegroundPolling();
    }
  }

  static Future<void> requestNotificationPermissions() async {
    await _requestNotificationPermissionIfNeeded();
  }

  static void setAppForegroundState(bool isForeground) {
    _isAppInForeground = isForeground;
    if (isForeground) {
      // Poll immediately when app returns to foreground to avoid stale delay.
      unawaited(pollAndNotify(allowWhenForeground: true));
    }
  }

  static Future<void> pollAndNotify({
    required bool allowWhenForeground,
  }) async {
    if (_isPollingNow) return;
    _isPollingNow = true;

    try {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString('device_ip')?.trim() ?? '';
    final port = prefs.getString('device_port')?.trim() ?? '';

    if (ip.isEmpty) return;

    final parsedPort = int.tryParse(port);
    final uri = Uri(
      scheme: 'http',
      host: ip,
      port: parsedPort ?? 80,
      path: '/api/status',
    );

      final response = await http.get(uri).timeout(
            const Duration(seconds: 3),
            onTimeout: () => throw Exception('Connection timeout'),
          );
      if (response.statusCode != 200) return;

      final rawBody = utf8.decode(response.bodyBytes, allowMalformed: true);
      dynamic decodedRaw;
      try {
        decodedRaw = jsonDecode(rawBody);
      } catch (_) {
        decodedRaw = jsonDecode(sanitizeJsonControlCharsInStrings(rawBody));
      }
      if (decodedRaw is! Map<String, dynamic>) return;

      final traffic = _trafficFromStatus(decodedRaw);
      final lastRx = traffic['lastReceived']?.toString().trim() ?? '';
      if (lastRx.isEmpty) return;

      final previousLastRx =
          prefs.getString('message_last_received_text')?.trim() ?? '';
      if (previousLastRx == lastRx) return;

      await prefs.setString('message_last_received_text', lastRx);

      final incoming = _parseIncomingMessage(lastRx);
      if (incoming == null) return;

      if (!allowWhenForeground && _isAppInForeground) return;

      await _showNotification(
        title: incoming.sender,
        body: incoming.text,
      );
    } catch (_) {
      // Keep background poll resilient; ignore transient network/parse errors.
    } finally {
      _isPollingNow = false;
    }
  }

  static Map<String, dynamic> _trafficFromStatus(Map<String, dynamic> data) {
    final traffic = data['traffic'];
    if (traffic is Map<String, dynamic>) return traffic;
    return data;
  }

  static _IncomingMessage? _parseIncomingMessage(String message) {
    if (message.startsWith('HELLO|')) return null;
    if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(message)) {
      return null;
    }

    final tagged = RegExp(
      r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(message);
    if (tagged != null) {
      var fromHex = (tagged.group(1) ?? '').toUpperCase();
      final text = (tagged.group(2) ?? '').trim();
      if (text.isEmpty) return null;
      if (fromHex.length == 2) fromHex = '00$fromHex';
      return _IncomingMessage(sender: 'Node 0x$fromHex', text: text);
    }

    final relay = RegExp(
      r'^RELAY\|([0-9A-Fa-f]{4})\|(.+)$',
      caseSensitive: false,
    ).firstMatch(message);
    if (relay != null) {
      final destHex = (relay.group(1) ?? '').toUpperCase();
      final text = (relay.group(2) ?? '').trim();
      if (text.isEmpty) return null;
      return _IncomingMessage(sender: 'Via relay -> 0x$destHex', text: text);
    }

    debugPrint('New message: $message');

    return _IncomingMessage(sender: 'New message', text: message);
  }

  static Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channel.id,
        _channel.name,
        channelDescription: _channel.description,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  static Future<void> _initializeNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _notifications.initialize(initSettings);

    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_channel);
  }

  static Future<void> _requestNotificationPermissionIfNeeded() async {
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    await iosPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    final macPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
    await macPlugin?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  static Future<void> _registerBackgroundPollingTask() async {
    await Workmanager().initialize(
      messageBackgroundCallbackDispatcher,
    );

    await Workmanager().registerPeriodicTask(
      _backgroundTaskUniqueName,
      _backgroundTaskName,
      frequency: const Duration(minutes: 15),
      initialDelay: const Duration(minutes: 1),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  static void _startForegroundPolling() {
    _foregroundTimer?.cancel();
    // Trigger immediately on startup; don't wait for first timer tick.
    unawaited(pollAndNotify(allowWhenForeground: true));
    _foregroundTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => pollAndNotify(allowWhenForeground: true),
    );
  }
}

class _IncomingMessage {
  const _IncomingMessage({
    required this.sender,
    required this.text,
  });

  final String sender;
  final String text;
}
