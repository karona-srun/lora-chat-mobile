import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../utils/group_wire_utils.dart';
import '../utils/gps_message_utils.dart';
import '../utils/json_string_sanitize.dart';
import '../services/local_database_service.dart';
import 'chat_unread_dot_service.dart';

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
  static const String _lastReceivedTextPrefKey = 'message_last_received_text';
  static const String _lastReceivedCountPrefKey = 'message_last_received_count';
  static const String _groupsChangedAtPrefKey = 'groups_changed_at_ms';
  static const String messageChangedAtMsKey = 'chat_messages_changed_at_ms';

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static const AndroidNotificationChannel _soundChannel =
      AndroidNotificationChannel(
        'lomhor_new_messages_sound',
        'New messages (sound)',
        description: 'Alerts when a new LoRa message is received.',
        importance: Importance.high,
        playSound: true,
      );
  static const AndroidNotificationChannel _silentChannel =
      AndroidNotificationChannel(
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
      unawaited(pollAndNotify(allowWhenForeground: true));
    }
  }

  static Future<void> pollAndNotify({required bool allowWhenForeground}) async {
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

      final response = await http
          .get(uri)
          .timeout(
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
      final currentReceivedCount = int.tryParse(
        (traffic['received'] ?? '').toString(),
      );

      final previousLastRx =
          prefs.getString(_lastReceivedTextPrefKey)?.trim() ?? '';
      final previousReceivedCount = prefs.getInt(_lastReceivedCountPrefKey);
      final isDuplicateByTextAndCount =
          previousLastRx == lastRx &&
          currentReceivedCount != null &&
          previousReceivedCount != null &&
          currentReceivedCount == previousReceivedCount;
      if (isDuplicateByTextAndCount) return;

      await prefs.setString(_lastReceivedTextPrefKey, lastRx);
      if (currentReceivedCount != null) {
        await prefs.setInt(_lastReceivedCountPrefKey, currentReceivedCount);
      }

      if (_containsControlFrame(lastRx, 'GROUP_INVITE')) {
        await _handleGroupInvite(lastRx);
      }
      if (_containsControlFrame(lastRx, 'GROUP_REMOVE')) {
        await _handleGroupRemove(lastRx);
      }
      if (_containsControlFrame(lastRx, 'GROUP_LEAVE')) {
        await _handleGroupLeave(lastRx);
      }
      if (_containsControlFrame(lastRx, 'GROUP_MEMBER_REMOVE')) {
        await _handleGroupMemberRemove(lastRx);
      }

      await _persistIncomingMessage(lastRx);

      final incoming = await _parseIncomingMessage(lastRx);
      if (incoming == null) return;

      await _markUnreadDotsFromFrame(lastRx);
      await _markMessagesChanged();

      if (!allowWhenForeground && _isAppInForeground) return;

      await _showNotification(title: incoming.sender, body: incoming.text);
    } catch (_) {
      // Keep loops operational across background context drops
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
    final normalizedRaw = _extractControlPayload(raw, 'GROUP_INVITE');
    if (normalizedRaw == null) return;
    final parts = normalizedRaw.split('|');
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
        ContactRecord(loraAddress: addr, displayName: displayName),
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
    await _markGroupsChanged();
  }

  static Future<void> _handleGroupRemove(String raw) async {
    final normalizedRaw = _extractControlPayload(raw, 'GROUP_REMOVE');
    if (normalizedRaw == null) return;
    final parts = normalizedRaw.split('|');
    if (parts.length < 2) return;
    final groupUuid = parts[1].trim();
    if (groupUuid.isEmpty) return;
    await LocalDatabaseService.instance.ensureInitialized();
    await LocalDatabaseService.instance.removeGroupByUuid(groupUuid);
    await _markGroupsChanged();
  }

  static Future<void> _handleGroupLeave(String raw) async {
    final normalizedRaw = _extractControlPayload(raw, 'GROUP_LEAVE');
    if (normalizedRaw == null) return;
    final parts = normalizedRaw.split('|');
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
    await _markGroupsChanged();
  }

  static Future<void> _handleGroupMemberRemove(String raw) async {
    final normalizedRaw = _extractControlPayload(raw, 'GROUP_MEMBER_REMOVE');
    if (normalizedRaw == null) return;
    final parts = normalizedRaw.split('|');
    if (parts.length < 3) return;
    final groupUuid = parts[1].trim();
    final contactId = int.tryParse(parts[2].trim());
    if (groupUuid.isEmpty || contactId == null) return;

    await LocalDatabaseService.instance.ensureInitialized();
    await LocalDatabaseService.instance.deactivateGroupMemberByUuid(
      groupUuid: groupUuid,
      contactId: contactId,
    );
    await _markGroupsChanged();
  }

  static Future<_IncomingMessage?> _parseIncomingMessage(String message) async {
    if (message.startsWith('HELLO|')) return null;
    if (_containsControlFrame(message, 'GROUP_INVITE')) return null;
    if (_containsControlFrame(message, 'GROUP_REMOVE')) return null;
    if (_containsControlFrame(message, 'GROUP_LEAVE')) return null;
    if (_containsControlFrame(message, 'GROUP_MEMBER_REMOVE')) return null;

    final relayDirect = _parseRelayDirectMessage(message);
    if (relayDirect != null) {
      return _IncomingMessage(
        sender: 'Node 0x${relayDirect.fromAddr} via relay',
        text: relayDirect.text,
      );
    }

    // --- PRIORITY 1: EXPLICITLY INTERCEPT AND RETURN MSG2 PROTOCOLS ---
    final pipeDirect2 = _parsePipeDirectMessage2(message);
    debugPrint("======== 11 =========");
    debugPrint(pipeDirect2.toString());
    if (pipeDirect2 != null) {
      return _IncomingMessage(
        sender: 'Node 0x${pipeDirect2.fromAddr}',
        text: pipeDirect2.text,
      );
    }

    // --- PRIORITY 2: CHECK FOR NESTED MSG2 VALUES WRAPPED IN GROUPS ---
    final pipeGroup = _parsePipeGroupMessage(message);
    if (pipeGroup != null) {
      final nestedM2 = _parsePipeDirectMessage2(pipeGroup.text);
      if (nestedM2 != null) {
        debugPrint("======== 22 =========");
        debugPrint(message);
        return _IncomingMessage(
          sender: 'Node 0x${nestedM2.fromAddr}',
          text: nestedM2.text,
        );
      }
      return _IncomingMessage(
        sender: pipeGroup.senderName,
        text: pipeGroup.text,
      );
    }

    if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(message)) {
      return null;
    }

    // --- PRIORITY 3: SEQUENTIAL EVALUATION FOR STANDARD TRANSMISSIONS ---
    final tagged = RegExp(
      r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(message);

    if (tagged != null) {
      var fromHex = (tagged.group(1) ?? '').toUpperCase();
      final taggedPayload = (tagged.group(2) ?? '').trim();
      if (taggedPayload.isEmpty) return null;
      if (fromHex.length == 2) fromHex = '00$fromHex';

      final embeddedGroup = _parsePipeGroupMessage(taggedPayload);
      if (embeddedGroup != null) {
        final innerNested = _parsePipeDirectMessage2(embeddedGroup.text);
        if (innerNested != null) {
          debugPrint("======== 33 =========");
          debugPrint(message);
          return _IncomingMessage(
            sender: 'Node 0x${innerNested.fromAddr}',
            text: innerNested.text,
          );
        }
        return _IncomingMessage(
          sender: embeddedGroup.senderName,
          text: embeddedGroup.text,
        );
      }

      final parsedTagged = _splitSenderFromPayload(taggedPayload);
      if (parsedTagged.text.isEmpty) return null;
      debugPrint("======== 44 =========");
      debugPrint(message);
      return _IncomingMessage(
        sender: parsedTagged.senderName ?? 'Node 0x$fromHex',
        text: parsedTagged.text,
      );
    }

    final pipeDirect = _parsePipeDirectMessage(message);
    if (pipeDirect != null) {
      debugPrint("========55 =========");
      debugPrint(message);
      return _IncomingMessage(
        sender: 'Node 0x${pipeDirect.fromAddr}',
        text: pipeDirect.text,
      );
    }

    final plain = _splitSenderFromPayload(message);
    if (plain.text.isEmpty) return null;
    return _IncomingMessage(
      sender: plain.senderName ?? 'New message',
      text: plain.text,
    );
  }

  static String _newMessageUuid(String prefix) {
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}';
  }

  static String _sanitizeIncomingText(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(RegExp(r'^\d+\|'), '').trimLeft();
    // Preserve UTF-8 message content (Khmer, emoji, etc.); remove only wire noise.
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
    return GpsMessageUtils.formatResponseMessage(text);
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

  static ({String fromAddr, String toAddr, String text})?
  _parseRelayDirectMessage(String raw) {
    final parts = raw.split('|').map((e) => e.trim()).toList();
    if (parts.length < 6 ||
        parts[0].toUpperCase() != 'RELAY' ||
        parts[2].toUpperCase() != 'MSG') {
      return null;
    }

    // Relayed legacy frames may append `R` to the source node address.
    final fromMatch = RegExp(
      r'^([0-9A-Fa-f]{2,4})R?$',
      caseSensitive: false,
    ).firstMatch(parts[3]);
    if (fromMatch == null) return null;

    final fromAddr = _normalizeAddress(parts[4]);
    final toAddr = _normalizeAddress(parts[1]);
    final text = _sanitizeIncomingText(parts.sublist(5).join('|'));
    if (fromAddr.isEmpty || toAddr.isEmpty || text.isEmpty) return null;
    return (fromAddr: fromAddr, toAddr: toAddr, text: text);
  }

  static ({String msgId, String fromAddr, String toAddr, String text})?
  _parsePipeDirectMessage2(String raw) {
    final parts = raw.split('|').map((e) => e.trim()).toList();
    debugPrint("======== RAW ============");
    debugPrint(raw);
    debugPrint("====================");
    final msg2Index = parts.indexWhere(
      (e) =>
          e.toUpperCase() == 'MSG' ||
          e.toUpperCase() == 'MSG2' ||
          e.toUpperCase() == 'MSG3',
    );
    if (msg2Index == -1 || parts.length < msg2Index + 5) return null;

    final msgId = parts[msg2Index + 1].trim();
    final fromAddr = _normalizeAddress(parts[msg2Index + 2]);
    final toAddr = _normalizeAddress(parts[msg2Index + 3]);
    final text = _sanitizeIncomingText(parts.sublist(msg2Index + 4).join('|'));

    if (msgId.isEmpty || fromAddr.isEmpty || toAddr.isEmpty || text.isEmpty) {
      return null;
    }

    return (msgId: msgId, fromAddr: fromAddr, toAddr: toAddr, text: text);
  }

  static ({
    String fromAddr,
    int groupId,
    String senderName,
    String senderAddr,
    String text,
  })?
  _parsePipeGroupMessage(String raw) {
    final parts = raw.split('|').map((e) => e.trim()).toList();
    String fromAddr = '';
    String groupToken = '';
    String payload = '';

    if (parts.length >= 5 && parts[2].toUpperCase() == 'GROUP_MSG') {
      fromAddr = _normalizeAddress(parts[0]);
      if (fromAddr.isEmpty) return null;
      groupToken = parts[3];
      payload = parts.sublist(4).join('|').trim();
    } else if (parts.length >= 3 && parts[0].toUpperCase() == 'GROUP_MSG') {
      groupToken = parts[1];
      payload = parts.sublist(2).join('|').trim();
    } else {
      return null;
    }

    if (groupToken.trim().isEmpty) return null;
    if (payload.isEmpty) return null;

    final senderMatch = RegExp(
      r'^([^&:|]+)&([0-9A-Fa-f]{2,8})\s*:\s*(.+)$',
    ).firstMatch(payload);
    if (senderMatch == null) return null;

    final senderName = (senderMatch.group(1) ?? '').trim();
    final senderAddr = _normalizeAddress(senderMatch.group(2) ?? '');
    final text = _sanitizeIncomingText(senderMatch.group(3) ?? '');
    if (senderName.isEmpty || senderAddr.isEmpty || text.isEmpty) return null;

    return (
      fromAddr: fromAddr,
      groupId: -1,
      senderName: senderName,
      senderAddr: senderAddr,
      text: text,
    );
  }

  static String? _groupTokenFromWire(String raw) {
    final parts = raw.split('|').map((e) => e.trim()).toList();
    if (parts.length >= 5 && parts[2].toUpperCase() == 'GROUP_MSG') {
      final t = parts[3].trim();
      return t.isEmpty ? null : t;
    }
    if (parts.length >= 3 && parts[0].toUpperCase() == 'GROUP_MSG') {
      final t = parts[1].trim();
      return t.isEmpty ? null : t;
    }
    return null;
  }

  static Future<GroupSummaryRecord?> _resolveGroupSummaryFromWireToken(
    String token,
  ) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return null;
    final groups = await LocalDatabaseService.instance.listGroups();
    for (final group in groups) {
      if (GroupWireUtils.tokenMatchesGroup(trimmed, group.groupUuid)) {
        return group;
      }
    }
    return null;
  }

  static Future<void> _markUnreadDotsFromFrame(String lastRx) async {
    if (_isIgnoredStatusNoise(lastRx)) return;
    if (_containsControlFrame(lastRx, 'GROUP_INVITE')) return;
    if (_containsControlFrame(lastRx, 'GROUP_REMOVE')) return;
    if (_containsControlFrame(lastRx, 'GROUP_LEAVE')) return;
    if (_containsControlFrame(lastRx, 'GROUP_MEMBER_REMOVE')) return;

    final prefs = await SharedPreferences.getInstance();
    final myAddr = _normalizeAddress(
      (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
    );

    final m2 = _parsePipeDirectMessage2(lastRx);
    if (m2 != null) {
      if (myAddr.isEmpty || m2.fromAddr != myAddr) {
        await ChatUnreadDotService.markDirectUnread(m2.fromAddr);
      }
      return;
    }

    final gCheck = _parsePipeGroupMessage(lastRx);
    if (gCheck != null) {
      final subM2 = _parsePipeDirectMessage2(gCheck.text);
      if (subM2 != null) {
        if (myAddr.isEmpty || subM2.fromAddr != myAddr) {
          await ChatUnreadDotService.markDirectUnread(subM2.fromAddr);
        }
        return;
      }
    }

    String? taggedInner;
    String? taggedFromHex;
    final tagged = RegExp(
      r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(lastRx);
    if (tagged != null) {
      taggedInner = tagged.group(2)?.trim();
      var fh = (tagged.group(1) ?? '').toUpperCase();
      if (fh.length == 2) fh = '00$fh';
      taggedFromHex = _normalizeAddress(fh);
    }

    final blobs = <String>[
      lastRx,
      if (taggedInner != null && taggedInner.isNotEmpty) taggedInner,
    ];

    for (final blob in blobs) {
      final g = _parsePipeGroupMessage(blob);
      if (g != null) {
        final token = _groupTokenFromWire(blob);
        final group = token == null
            ? null
            : await _resolveGroupSummaryFromWireToken(token);
        if (group != null && (myAddr.isEmpty || g.senderAddr != myAddr)) {
          await ChatUnreadDotService.markGroupUnread(group.groupUuid);
        }
        return;
      }
    }

    for (final blob in blobs) {
      final d = _parsePipeDirectMessage(blob);
      if (d != null) {
        if (myAddr.isEmpty || d.fromAddr != myAddr) {
          await ChatUnreadDotService.markDirectUnread(d.fromAddr);
        }
        return;
      }
    }

    if (taggedFromHex != null &&
        taggedFromHex.isNotEmpty &&
        (myAddr.isEmpty || taggedFromHex != myAddr)) {
      await ChatUnreadDotService.markDirectUnread(taggedFromHex);
    }
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

    if (!saveDbEnabled) return;
    if (_isIgnoredStatusNoise(raw)) return;

    await LocalDatabaseService.instance.ensureInitialized();
    final selfContactId = await _ensureSelfContact();
    final myAddr = _normalizeAddress(
      (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
    );

    final relayDirect = _parseRelayDirectMessage(raw);
    debugPrint("========== relayDirect =========");
    debugPrint(relayDirect.toString());
    if (relayDirect != null) {
      final fromContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: relayDirect.fromAddr,
          displayName: 'Node 0x${relayDirect.fromAddr}',
        ),
      );
      final toContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: relayDirect.toAddr,
          displayName: relayDirect.toAddr == myAddr
              ? 'You'
              : 'Node 0x${relayDirect.toAddr}',
        ),
      );
      final isDuplicate = await LocalDatabaseService.instance
          .hasRecentDuplicateIncomingMessage(
            chatType: ChatType.direct,
            fromContactId: fromContactId,
            toContactId: toContactId,
            payload: relayDirect.text,
          );
      if (!isDuplicate) {
        final insertedId = await LocalDatabaseService.instance.insertMessage(
          MessageRecord(
            messageUuid: _newMessageUuid('relay_dm'),
            chatType: ChatType.direct,
            fromContactId: fromContactId.toString(),
            toContactId: toContactId.toString(),
            payload: relayDirect.text,
            deliveryStatus: DeliveryStatus.delivered,
            receivedAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        if (insertedId != null) await _markMessagesChanged();
      }
      return;
    }

    final pipeDirect2 = _parsePipeDirectMessage2(raw);
    if (pipeDirect2 != null) {
      await _saveDirectMsg2ToDatabase(pipeDirect2, myAddr);
      return;
    }

    final groupCheck = _parsePipeGroupMessage(raw);
    if (groupCheck != null) {
      final nestedM2 = _parsePipeDirectMessage2(groupCheck.text);
      if (nestedM2 != null) {
        await _saveDirectMsg2ToDatabase(nestedM2, myAddr);
        return;
      }
    }

    if (_containsControlFrame(raw, 'GROUP_INVITE')) {
      await _handleGroupInvite(raw);
      return;
    }
    if (_containsControlFrame(raw, 'GROUP_MEMBER_REMOVE')) {
      await _handleGroupMemberRemove(raw);
      return;
    }

    if (groupCheck != null) {
      final parts = raw.split('|').map((e) => e.trim()).toList();
      String? groupToken;
      if (parts.length >= 5 && parts[2].toUpperCase() == 'GROUP_MSG') {
        groupToken = parts[3];
      } else if (parts.length >= 3 && parts[0].toUpperCase() == 'GROUP_MSG') {
        groupToken = parts[1];
      }
      final group = groupToken == null
          ? null
          : await _resolveGroupSummaryFromWireToken(groupToken);
      final groupDbId = group?.groupId;
      if (groupDbId == null) return;

      final fromContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: groupCheck.senderAddr,
          displayName: groupCheck.senderName,
        ),
      );
      final isDuplicate = await LocalDatabaseService.instance
          .hasRecentDuplicateIncomingMessage(
            chatType: ChatType.group,
            fromContactId: fromContactId,
            groupId: groupDbId,
            payload: groupCheck.text,
          );
      if (!isDuplicate) {
        final insertedId = await LocalDatabaseService.instance.insertMessage(
          MessageRecord(
            messageUuid: _newMessageUuid('grp_$groupDbId'),
            chatType: ChatType.group,
            fromContactId: fromContactId.toString(),
            groupId: groupDbId.toString(),
            payload: groupCheck.text,
            deliveryStatus: DeliveryStatus.delivered,
            receivedAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
        if (insertedId != null) await _markMessagesChanged();
      }
      return;
    }

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
          displayName: pipeDirect.toAddr == myAddr
              ? 'You'
              : 'Node 0x${pipeDirect.toAddr}',
        ),
      );
      final isDuplicate = await LocalDatabaseService.instance
          .hasRecentDuplicateIncomingMessage(
            chatType: ChatType.direct,
            fromContactId: fromContactId,
            toContactId: toContactId,
            payload: pipeDirect.text,
          );
      if (!isDuplicate) {
        final insertedId = await LocalDatabaseService.instance.insertMessage(
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
        if (insertedId != null) await _markMessagesChanged();
      }
      return;
    }

    final fromTagged = RegExp(
      r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (fromTagged != null) {
      final fromAddr = _normalizeAddress(fromTagged.group(1) ?? '');
      final taggedPayload = (fromTagged.group(2) ?? '').trim();
      if (fromAddr.isEmpty || taggedPayload.isEmpty) return;
      if (_isGroupTrafficFrame(taggedPayload)) {
        final subGroup = _parsePipeGroupMessage(taggedPayload);
        if (subGroup != null) {
          final subM2 = _parsePipeDirectMessage2(subGroup.text);
          if (subM2 != null) {
            await _saveDirectMsg2ToDatabase(subM2, myAddr);
            return;
          }
        }
        return;
      }

      final parsed = _splitSenderFromPayload(taggedPayload);
      if (parsed.text.isEmpty) return;
      final fromContactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: fromAddr,
          displayName: parsed.senderName ?? 'Node 0x$fromAddr',
        ),
      );
      final insertedId = await LocalDatabaseService.instance.insertMessage(
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
      if (insertedId != null) await _markMessagesChanged();
      return;
    }
  }

  static Future<void> _saveDirectMsg2ToDatabase(
    ({String msgId, String fromAddr, String toAddr, String text}) data,
    String myAddr,
  ) async {
    final fromContactId = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: data.fromAddr,
        displayName: 'Node 0x${data.fromAddr}',
      ),
    );

    final toContactId = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: data.toAddr,
        displayName: data.toAddr == myAddr ? 'You' : 'Node 0x${data.toAddr}',
      ),
    );

    final isDuplicate = await LocalDatabaseService.instance
        .hasRecentDuplicateIncomingMessage(
          chatType: ChatType.direct,
          fromContactId: fromContactId,
          toContactId: toContactId,
          payload: data.text,
        );

    if (!isDuplicate) {
      final insertedId = await LocalDatabaseService.instance.insertMessage(
        MessageRecord(
          messageUuid: 'msg_${data.msgId}',
          chatType: ChatType.direct,
          fromContactId: fromContactId.toString(),
          toContactId: toContactId.toString(),
          payload: data.text,
          deliveryStatus: DeliveryStatus.delivered,
          receivedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      if (insertedId != null) await _markMessagesChanged();
      debugPrint(
        'MSG2 ROUTED TO DIRECT SUCCESSFULLY: ${data.fromAddr} -> ${data.toAddr} : ${data.text}',
      );
    }
  }

  static bool _isIgnoredStatusNoise(String message) {
    if (message.startsWith('HELLO|')) return true;
    return false;
  }

  static bool _isGroupTrafficFrame(String payload) {
    final text = payload.trim().toUpperCase();
    if (text.isEmpty) return false;
    return text.startsWith('GROUP_MSG|') ||
        text.contains('|GROUP_MSG|') ||
        text.contains('GROUP_INVITE|') ||
        text.contains('GROUP_REMOVE|') ||
        text.contains('GROUP_LEAVE|') ||
        text.contains('GROUP_MEMBER_REMOVE|');
  }

  static String? _extractControlPayload(String raw, String controlType) {
    final marker = '$controlType|';
    final directIndex = raw.indexOf(marker);
    if (directIndex >= 0) {
      return raw.substring(directIndex).trim();
    }

    final taggedMatch = RegExp(
      r'^From 0x[0-9A-Fa-f]{2,4}\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(raw);
    final taggedPayload = taggedMatch?.group(1)?.trim();
    if (taggedPayload == null || taggedPayload.isEmpty) return null;
    final taggedIndex = taggedPayload.indexOf(marker);
    if (taggedIndex < 0) return null;
    return taggedPayload.substring(taggedIndex).trim();
  }

  static bool _containsControlFrame(String raw, String controlType) {
    return _extractControlPayload(raw, controlType) != null;
  }

  static Future<void> _markGroupsChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _groupsChangedAtPrefKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<void> _markMessagesChanged() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      messageChangedAtMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<void> _showNotification({
    required String title,
    required String body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final soundEnabled =
        prefs.getBool(_notificationSoundEnabledPrefKey) ?? true;
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

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_soundChannel);
    await androidPlugin?.createNotificationChannel(_silentChannel);
  }

  static Future<void> _requestNotificationPermissionIfNeeded() async {
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();

    final iosPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);

    final macPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    await macPlugin?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static Future<void> _registerBackgroundPollingTask() async {
    await Workmanager().initialize(messageBackgroundCallbackDispatcher);

    await Workmanager().registerPeriodicTask(
      _backgroundTaskUniqueName,
      _backgroundTaskName,
      frequency: const Duration(minutes: 15),
      initialDelay: const Duration(minutes: 1),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  static void _startForegroundPolling() {
    _foregroundTimer?.cancel();
    unawaited(pollAndNotify(allowWhenForeground: true));
    _foregroundTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => pollAndNotify(allowWhenForeground: true),
    );
  }
}

class _IncomingMessage {
  const _IncomingMessage({required this.sender, required this.text});

  final String sender;
  final String text;
}
