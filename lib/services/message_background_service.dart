import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/json_string_sanitize.dart';
import '../services/local_database_service.dart';

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
  static const String _saveDatabaseLocallyPrefKey = 'save_database_locally';
  static const String _notificationSoundEnabledPrefKey =
      'notification_sound_enabled';

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static const AndroidNotificationChannel _soundChannel = AndroidNotificationChannel(
    'lomhor_new_messages_sound',
    'New messages (sound)',
    description: 'Alerts when a new LoRa message is received.',
    importance: Importance.high,
    playSound: true,
  );
  static const AndroidNotificationChannel _silentChannel = AndroidNotificationChannel(
    'lomhor_new_messages_silent',
    'New messages (silent)',
    description: 'Alerts when a new LoRa message is received.',
    importance: Importance.high,
    playSound: false,
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

      if (lastRx.startsWith('GROUP_INVITE|')) {
        await _handleGroupInvite(lastRx);
      }
      if (lastRx.startsWith('GROUP_REMOVE|')) {
        await _handleGroupRemove(lastRx);
      }
      if (lastRx.startsWith('GROUP_LEAVE|')) {
        await _handleGroupLeave(lastRx);
      }

      await _persistIncomingMessage(lastRx);

      final incoming = await _parseIncomingMessage(lastRx);
      if (incoming == null) return;

      // debugPrint('incoming: ${incoming.sender} ${incoming.text}');    

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

  static String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  static Future<void> _handleGroupInvite(String raw) async {
    final parts = raw.split('|');
    if (parts.length < 4) return;

    final groupUuid = parts[1].trim();
    final groupName = parts[2].trim();
    final ownerAddrRaw = parts[3].trim();
    final membersRaw = parts.length > 4 ? parts[4].trim() : '';

    if (groupUuid.isEmpty || groupName.isEmpty) return;

    final ownerAddr = _normalizeAddress(ownerAddrRaw);
    if (ownerAddr.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final myAddrPref =
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim();
    final myAddr = _normalizeAddress(myAddrPref);

    await LocalDatabaseService.instance.ensureInitialized();

    Future<int> ensureContact(String addr) {
      final displayName = '0x$addr';
      return LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: addr,
          displayName: displayName,
        ),
      );
    }

    final ownerContactId = await ensureContact(ownerAddr);

    await LocalDatabaseService.instance.upsertGroup(
      GroupRecord(
        groupUuid: groupUuid,
        groupName: groupName,
        ownerContactId: ownerContactId,
      ),
    );

    final memberAddrs = <String>{};
    if (ownerAddr.isNotEmpty) memberAddrs.add(ownerAddr);
    if (membersRaw.isNotEmpty) {
      for (final part in membersRaw.split(',')) {
        final rawMember = part.trim();
        final addrPart = rawMember.contains(':')
            ? rawMember.split(':').last.trim()
            : rawMember.contains('&')
                ? rawMember.split('&').last.trim()
                : rawMember;
        final addr = _normalizeAddress(addrPart);
        if (addr.isNotEmpty) {
          memberAddrs.add(addr);
        }
      }
    }

    if (myAddr.isNotEmpty) {
      memberAddrs.add(myAddr);
    }

    for (final addr in memberAddrs) {
      final contactId = await ensureContact(addr);
      final role = addr == ownerAddr
          ? GroupMemberRole.owner
          : GroupMemberRole.member;

      await LocalDatabaseService.instance.upsertGroupMember(
        GroupMemberRecord(
          groupUuid: groupUuid,
          contactId: contactId,
          role: role,
          isActive: true,
        ),
      );
    }
  }

  static Future<void> _handleGroupRemove(String raw) async {
    final parts = raw.split('|');
    if (parts.length < 2) return;
    final groupUuid = parts[1].trim();
    if (groupUuid.isEmpty) return;

    await LocalDatabaseService.instance.ensureInitialized();
    await LocalDatabaseService.instance.removeGroupByUuid(groupUuid);
  }

  static Future<void> _handleGroupLeave(String raw) async {
    // Format: GROUP_LEAVE|<groupUuid>|<contactId>
    final parts = raw.split('|');
    if (parts.length < 3) return;
    final groupUuid = parts[1].trim();
    final contactIdStr = parts[2].trim();
    if (groupUuid.isEmpty || contactIdStr.isEmpty) return;
    final contactId = int.tryParse(contactIdStr);
    if (contactId == null) return;

    await LocalDatabaseService.instance.ensureInitialized();
    await LocalDatabaseService.instance.deactivateGroupMemberByUuid(
      groupUuid: groupUuid,
      contactId: contactId,
    );
  }

  static Future<_IncomingMessage?> _parseIncomingMessage(String message) async {
    if (message.startsWith('HELLO|')) return null;
    if (message.startsWith('GROUP_INVITE|')) return null;
    if (message.startsWith('GROUP_REMOVE|')) return null;
    if (message.startsWith('GROUP_LEAVE|')) return null;
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
      final text = (relay.group(2) ?? '').trim();
      if (text.isEmpty) return null;
      // return _IncomingMessage(sender: 'Via relay -> 0x$destHex', text: text);
      return _IncomingMessage(sender: 'New message', text: text);
    }
    if (message.contains('GROUP_INVITE|') || message.contains('GROUP_INVITEI')) {
      // create group is auto when got group invite into database
      
      final groupUuid = message.split('|')[3];
      final groupName = message.split('|')[4];
      final ownerAddr = message.split('|')[5];
      final members = message.split('|')[6];
      final ownerContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: ownerAddr,
          displayName: ownerAddr,
        ),
      );
      await LocalDatabaseService.instance.upsertGroup(
        GroupRecord(
          groupUuid: groupUuid,
          groupName: groupName,
          ownerContactId: ownerContactId,
        ),
      );
      for (final member in members.split(',')) {
        final memberContactId = await LocalDatabaseService.instance.upsertContact(
          ContactRecord(
            loraAddress: member,
            displayName: member,
          ),
        );
        await LocalDatabaseService.instance.upsertGroupMember(
          GroupMemberRecord(
            groupUuid: groupUuid,
            contactId: memberContactId,
            role: GroupMemberRole.member,
            isActive: true,
          ),
        );
      }
      return _IncomingMessage(sender: 'New group invite', text: message.trim());
    }
    if (message.contains('GROUP_REMOVE|')) {
      return _IncomingMessage(sender: 'New group remove', text: message.trim());
    }
    if (message.contains('GROUP_LEAVE|')) {
      return _IncomingMessage(sender: 'New group leave', text: message.trim());
    }
    final msg = message.split('|');
    final text = msg[2];
    if(message.contains('GROUP_MSG')){
      return _IncomingMessage(sender: "Group message", text: msg[4].trimLeft());
    }else{
      return _IncomingMessage(sender: "Direct message", text: text.trimLeft());
    }
  }

  static String _newMessageUuid(String prefix) {
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}';
  }

  static String _sanitizeIncomingText(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(RegExp(r'^\d+\|'), '').trimLeft();
    text = text.replaceFirst(RegExp(r'[^\x20-\x7E]+$'), '').trimRight();
    return text;
  }

  static ({String? senderName, String text}) _splitSenderFromPayload(
    String payload,
  ) {
    var trimmed = payload.trim();
    if (trimmed.isEmpty) return (senderName: null, text: '');

    final numericPrefix = RegExp(r'^\d+\|').firstMatch(trimmed);
    if (numericPrefix != null) {
      trimmed = trimmed.substring(numericPrefix.end).trimLeft();
      if (trimmed.isEmpty) return (senderName: null, text: '');
    }

    final colonMatch = RegExp(r'^([^:]{1,24})\s*:\s*(.+)$').firstMatch(trimmed);
    if (colonMatch != null) {
      final sender = (colonMatch.group(1) ?? '').trim();
      final text = _sanitizeIncomingText(colonMatch.group(2) ?? '');
      if (sender.isNotEmpty && text.isNotEmpty) {
        return (senderName: sender, text: text);
      }
    }
    return (senderName: null, text: _sanitizeIncomingText(trimmed));
  }

  static ({String fromAddr, String toAddr, String text})?
      _parsePipeDirectMessage(String raw) {
    final parts = raw.split('|').map((e) => e.trim()).toList();
    if (parts.length < 3) return null;
    final fromAddr = _normalizeAddress(parts[0]);
    final toAddr = _normalizeAddress(parts[1]);
    final text = _sanitizeIncomingText(parts.sublist(2).join('|'));
    if (fromAddr.isEmpty || toAddr.isEmpty || text.isEmpty) return null;
    return (fromAddr: fromAddr, toAddr: toAddr, text: text);
  }

  static Future<int> _ensureSelfContact() async {
    final prefs = await SharedPreferences.getInstance();
    final myCallSign = (prefs.getString('callSign') ?? '').trim();
    final myAddr = _normalizeAddress(
      (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
    );
    return LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: myAddr.isNotEmpty ? myAddr : '__SELF__',
        displayName: myCallSign.isNotEmpty ? myCallSign : 'You',
      ),
    );
  }

  static Future<void> _persistIncomingMessage(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    final saveDbEnabled = prefs.getBool(_saveDatabaseLocallyPrefKey) ?? false;
    // Respect setting: only persist incoming messages when local DB saving is enabled.
    if (!saveDbEnabled) return;
    if (_isIgnoredStatusNoise(raw)) return;
    if (raw.contains('GROUP_INVITE|') || raw.contains('GROUP_INVITET|')) {
      // Auto-create/update group and members from invite payload.
      await _handleGroupInvite(raw);
      return;
    }

    await LocalDatabaseService.instance.ensureInitialized();
    final selfContactId = await _ensureSelfContact();

    final pipeDirect = _parsePipeDirectMessage(raw);
    if (pipeDirect != null) {
      final fromContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: pipeDirect.fromAddr,
          displayName: 'Node 0x${pipeDirect.fromAddr}',
        ),
      );
      final toContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: pipeDirect.toAddr,
          displayName: pipeDirect.toAddr == _normalizeAddress(
                  (await SharedPreferences.getInstance())
                          .getString('myAddr') ??
                      (await SharedPreferences.getInstance())
                          .getString('my_addr') ??
                      '')
              ? 'You'
              : 'Node 0x${pipeDirect.toAddr}',
        ),
      );
      final isDuplicate =
          await LocalDatabaseService.instance.hasRecentDuplicateIncomingMessage(
        chatType: ChatType.direct,
        fromContactId: fromContactId,
        toContactId: toContactId,
        payload: pipeDirect.text,
      );
      if (!isDuplicate) {
        await LocalDatabaseService.instance.insertMessage(
          MessageRecord(
            messageUuid: _newMessageUuid('dm'),
            chatType: ChatType.direct,
            fromContactId: fromContactId.toString(),
            toContactId: toContactId.toString(),
            payload: pipeDirect.text,
            deliveryStatus: DeliveryStatus.delivered,
            receivedAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
      }
      debugPrint('Message is saved to database');
      return;
    }

    final fromTagged = RegExp(
      r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (fromTagged != null) {
      final fromAddr = _normalizeAddress(fromTagged.group(1) ?? '');
      final parsed = _splitSenderFromPayload(fromTagged.group(2) ?? '');
      if (fromAddr.isEmpty || parsed.text.isEmpty) return;

      final fromContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: fromAddr,
          displayName: parsed.senderName ?? 'Node 0x$fromAddr',
        ),
      );



      debugPrint('Persist Incoming Message : $raw');
      final msg = raw.split('|');
      final fromId = msg[1];
      final toId = msg[2];
      final text = msg[3];
    // debugPrint('fromContactId: $fromContactId');
    // debugPrint('toContactId: $toContactId');
    // debugPrint('text: $text');

    final messageUuid = await LocalDatabaseService.instance.insertMessage(
      MessageRecord(
        messageUuid: _newMessageUuid('dm'),
        chatType: ChatType.direct,
        fromContactId: fromId.toString(),
        toContactId: toId.toString(),
        payload: text.toString(),
        deliveryStatus: DeliveryStatus.delivered,
        receivedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );

    if (messageUuid != null){
      debugPrint('Message is saved to database');
      debugPrint('messageUuid: $messageUuid');
    }

      await LocalDatabaseService.instance.insertMessage(
        MessageRecord(
          messageUuid: _newMessageUuid('dm'),
          chatType: ChatType.direct,
          fromContactId: fromContactId.toString(),
          toContactId: selfContactId.toString(),
          payload: parsed.text,
          deliveryStatus: DeliveryStatus.delivered,
          receivedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );

      final fromGroups =
          await LocalDatabaseService.instance.listActiveGroupIdsForContact(
        fromContactId,
      );
      if (fromGroups.isEmpty) return;
      final selfGroups =
          await LocalDatabaseService.instance.listActiveGroupIdsForContact(
        selfContactId,
      );
      final selfGroupSet = selfGroups.toSet();
      for (final groupId in fromGroups) {
        if (!selfGroupSet.contains(groupId)) continue;
        await LocalDatabaseService.instance.insertMessage(
          MessageRecord(
            messageUuid: _newMessageUuid('grp_$groupId'),
            chatType: ChatType.group,
            fromContactId: fromContactId.toString(),
            groupId: groupId.toString(),
            payload: parsed.text,
            deliveryStatus: DeliveryStatus.delivered,
            receivedAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
      }
      return;
    }

    final plain = _splitSenderFromPayload(raw);
    if (plain.text.isEmpty || plain.senderName == null) return;

    final sender = plain.senderName!.trim();
    if (sender.isEmpty) return;
    final senderContactId = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: '__GROUP_SENDER__${sender.toUpperCase()}',
        displayName: sender,
      ),
    );
    final senderGroups =
        await LocalDatabaseService.instance.listActiveGroupIdsForContact(
      senderContactId,
    );
    for (final groupId in senderGroups) {
      await LocalDatabaseService.instance.insertMessage(
        MessageRecord(
          messageUuid: _newMessageUuid('grp_$groupId'),
          chatType: ChatType.group,
          fromContactId: senderContactId.toString(),
          groupId: groupId.toString(),
          payload: plain.text,
          deliveryStatus: DeliveryStatus.delivered,
          receivedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
    }
  }

  static bool _isIgnoredStatusNoise(String message) {
    if (message.startsWith('HELLO|')) return true;
    if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(message)) {
      return true;
    }
    return false;
  }

  static Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final soundEnabled = prefs.getBool(_notificationSoundEnabledPrefKey) ?? true;
    final channel = soundEnabled ? _soundChannel : _silentChannel;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: Importance.high,
        priority: Priority.high,
        playSound: soundEnabled,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: soundEnabled,
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
    await androidPlugin?.createNotificationChannel(_soundChannel);
    await androidPlugin?.createNotificationChannel(_silentChannel);
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
