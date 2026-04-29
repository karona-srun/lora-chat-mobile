import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:context_menu_android/features/context_menu/data/models/context_menu.dart';
import 'package:context_menu_android/features/context_menu/presentation/widget/ios_style_context_menu.dart';
import 'dart:convert';
import 'dart:async';
import '../models/chat_message.dart';
import 'group_details_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_database_service.dart';
import '../utils/json_string_sanitize.dart';
import '../widgets/chat_bubble.dart';
import '../l10n/app_localizations.dart';

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.groupId,
    required this.groupUuid,
    required this.groupTitle,
  });

  final int groupId;
  final String groupUuid;
  final String groupTitle;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  static const String _saveDatabaseLocallyPrefKey = 'save_database_locally';
  static const String _powerModePrefKey = 'power_mode';
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  bool _saveDatabaseLocallyEnabled = false;
  String _powerMode = 'powerModeBalanced';

  int get _maxMessageLength =>
      _powerMode == 'powerModeBalanced' ? 100 : 50;
  final List<ChatMessage> _messages = [];
  List<GroupMemberContactRecord> _groupMembers = const <GroupMemberContactRecord>[];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  List<String> _targetHexes = const <String>[];
  String _selfCallSign = '';
  String _selfAddr = '';
  int? _selfContactId;
  String _lastRxText = '';
  int? _lastRxReceivedCount;
  int _currentMessageLength = 0;
  final Map<int, String> _messageUuidByIndex = <int, String>{};

  @override
  void initState() {
    super.initState();
    _messages.add(
      ChatMessage(
        text: 'Group chat ready. Messages will be sent to all members.',
        sender: 'System',
        timestamp: DateTime.now(),
        isSystem: true,
      ),
    );
    _loadConnectionPrefs();
    _loadGroupMembers();
    _messagePollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _fetchMessages(),
    );
    _loadGroupMessagesFromDb();
    _fetchMessages();
  }

  @override
  void didUpdateWidget(GroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _lastRxText = '';
      _lastRxReceivedCount = null;
      _messageUuidByIndex.clear();
      _messages
        ..clear()
        ..add(
          ChatMessage(
            text: 'Group chat ready. Messages will be sent to all members.',
            sender: 'System',
            timestamp: DateTime.now(),
            isSystem: true,
          ),
        );
      _loadGroupMembers();
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _messagePollTimer?.cancel();
    super.dispose();
  }

  String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    // Always normalize to 4-hex-digit node IDs, matching background service.
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  Future<void> _loadConnectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();
      final saveDbEnabled = prefs.getBool(_saveDatabaseLocallyPrefKey) ?? false;
      final storedPowerMode = prefs.getString(_powerModePrefKey);
      final myCallSign = (prefs.getString('callSign') ?? '').trim().toUpperCase();
      final myAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );

      if (!mounted) return;

      setState(() {
        deviceIp =
            (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        devicePort =
            (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';
        _isConnected = deviceIp.isNotEmpty;
        _saveDatabaseLocallyEnabled = saveDbEnabled;
        _selfCallSign = myCallSign;
        _selfAddr = myAddr;
        if (storedPowerMode != null && storedPowerMode.isNotEmpty) {
          _powerMode = storedPowerMode;
        }
        _currentMessageLength =
            _currentMessageLength.clamp(0, _maxMessageLength);
      });
      // Re-resolve targets now that self address / callsign are known.
      await _loadGroupMembers();
      await _ensureSelfContact();
      await _loadGroupMessagesFromDb();
    } catch (e) {
      debugPrint('Failed to load connection prefs: $e');
    }
  }

  Future<void> _loadGroupMembers() async {
    final int requestedGroupId = widget.groupId;
    try {
      final details = await LocalDatabaseService.instance.getGroupDetails(
        requestedGroupId,
      );
      if (!mounted || details == null) return;
      if (details.groupId != requestedGroupId) return;
      if (widget.groupId != requestedGroupId) return;
      final resolvedTargets = _resolveTargetsFromMembers(details.members);
      setState(() {
        _groupMembers = details.members;
        _targetHexes = resolvedTargets;
      });
      await _loadGroupMessagesFromDb();
    } catch (e) {
      debugPrint('Failed to load group members: $e');
    }
  }

  String _newMessageUuid() {
    return '${widget.groupUuid}_${DateTime.now().microsecondsSinceEpoch}_${_messages.length}';
  }

  DateTime _parseMessageTime(MessageRecord record) {
    final raw = record.sentAt ?? record.receivedAt ?? record.createdAt ?? '';
    return DateTime.tryParse(raw)?.toLocal() ?? DateTime.now();
  }

  MessageDeliveryStatus _toUiDeliveryStatus(DeliveryStatus status) {
    switch (status) {
      case DeliveryStatus.pending:
        return MessageDeliveryStatus.sending;
      case DeliveryStatus.sent:
      case DeliveryStatus.delivered:
        return MessageDeliveryStatus.acked;
      case DeliveryStatus.failed:
        return MessageDeliveryStatus.failed;
    }
  }

  DeliveryStatus _toDbDeliveryStatus(MessageDeliveryStatus status) {
    switch (status) {
      case MessageDeliveryStatus.sending:
        return DeliveryStatus.pending;
      case MessageDeliveryStatus.acked:
        return DeliveryStatus.delivered;
      case MessageDeliveryStatus.noAck:
      case MessageDeliveryStatus.failed:
        return DeliveryStatus.failed;
      case MessageDeliveryStatus.none:
        return DeliveryStatus.sent;
    }
  }

  Future<void> _ensureSelfContact() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCallSign = (prefs.getString('callSign') ?? '').trim();
      final myAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );
      final id = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: myAddr.isNotEmpty ? myAddr : '__SELF__',
          displayName: myCallSign.isNotEmpty ? myCallSign : 'You',
        ),
      );
      _selfContactId = id;
    } catch (e) {
      debugPrint('Failed to ensure self contact: $e');
    }
  }

  String _senderLabelForContactId(String contactId) {
    if (_selfContactId != null && contactId == _selfContactId) return 'You';
    for (final member in _groupMembers) {
      if (member.contactId == contactId) {
        final name = member.displayName.trim();
        if (name.isNotEmpty) return name;
      }
    }
    return 'Member #$contactId';
  }

  Future<void> _loadGroupMessagesFromDb() async {
    if (!_saveDatabaseLocallyEnabled) return;
    try {
      final records = await LocalDatabaseService.instance.listGroupMessages(
        groupUuid: widget.groupUuid,
      );

      debugPrint(
        '[GroupChat] Open groupUuid=${widget.groupUuid} '
        '(groupId=${widget.groupId}) -> loaded ${records.length} message(s)',
      );
      for (final record in records) {
        final payload = record.payload.replaceAll('\n', r'\n');
        final shortPayload = payload.length > 120
            ? '${payload.substring(0, 120)}...'
            : payload;
        debugPrint(
          '[GroupChat] [${widget.groupUuid}] '
          'from=${record.fromContactId} uuid=${record.messageUuid} '
          'text="$shortPayload"',
        );
      }

      if (!mounted) return;
      setState(() {
        _messageUuidByIndex.clear();
        _messages
          ..clear()
          ..addAll(
            records.asMap().entries.map((entry) {
              final i = entry.key;
              final record = entry.value;
              _messageUuidByIndex[i] = record.messageUuid;
              return ChatMessage(
                text: record.payload,
                sender: _senderLabelForContactId(record.fromContactId.toString()),
                timestamp: _parseMessageTime(record),
                isSystem: false,
                deliveryStatus: _toUiDeliveryStatus(record.deliveryStatus),
              );
            }),
          );
        if (_messages.isEmpty) {
          _messages.add(
            ChatMessage(
              text: 'Group chat ready. Messages will be sent to all members.',
              sender: 'System',
              timestamp: DateTime.now(),
              isSystem: true,
            ),
          );
        }
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('Failed to load group messages: $e');
    }
  }

  Future<void> _persistGroupMessage({
    required String messageUuid,
    required int fromContactId,
    required String payload,
    required MessageDeliveryStatus status,
    bool isIncoming = false,
  }) async {
    if (!_saveDatabaseLocallyEnabled) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await LocalDatabaseService.instance.insertMessage(
      MessageRecord(
        messageUuid: messageUuid,
        chatType: ChatType.group,
        fromContactId: fromContactId.toString(),
        groupId: widget.groupId.toString(),
        payload: payload,
        deliveryStatus: _toDbDeliveryStatus(status),
        sentAt: isIncoming ? null : now,
        receivedAt: isIncoming ? now : null,
      ),
    );
  }

  Future<int?> _findContactIdForAddress(String addressHex) async {
    final normalized = _normalizeAddress(addressHex);
    if (normalized.isEmpty) return null;
    for (final member in _groupMembers) {
      final memberAddr = _normalizeAddress(member.loraAddress);
      if (memberAddr == normalized) return member.contactId;
    }
    final id = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: normalized,
        displayName: '0x$normalized',
      ),
    );
    return id;
  }

  List<String> _resolveTargetsFromMembers(List<GroupMemberContactRecord> members) {
    final uniqueTargets = <String>{};
    for (final member in members) {
      final normalizedAddress = _normalizeAddress(member.loraAddress);
      if (normalizedAddress.isEmpty) continue;
      if (normalizedAddress == '__SELF__') continue;
      if (_selfAddr.isNotEmpty && normalizedAddress == _selfAddr) continue;
      uniqueTargets.add(normalizedAddress);
    }
    return uniqueTargets.toList()..sort();
  }

  String _targetLabel() {
    if (_targetHexes.isEmpty) return AppLocalizations.of(context).tr('noMembers');
    if (_targetHexes.length == 1) return '2 ${AppLocalizations.of(context).tr('members')}';
    return '${_targetHexes.length + 1} ${AppLocalizations.of(context).tr('members')}';
  }

  /// Device JSON may include raw LoRa payloads; strict UTF-8 on [http.Response.body] throws.
  String _decodeResponseBody(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Map<String, dynamic> _trafficFromStatus(Map<String, dynamic> data) {
    final traffic = data['traffic'];
    if (traffic is Map<String, dynamic>) return traffic;
    return data;
  }

  bool _isGroupMemberAddress(String addressHex) {
    final normalized = _normalizeAddress(addressHex);
    if (normalized.isEmpty) return false;
    for (final member in _groupMembers) {
      final memberAddr = _normalizeAddress(member.loraAddress);
      if (memberAddr == normalized) return true;
    }
    return false;
  }

  String _senderLabelForAddress(String addressHex) {
    final normalized = _normalizeAddress(addressHex);
    if (normalized.isEmpty) return 'Unknown node';
    for (final member in _groupMembers) {
      final memberAddr = _normalizeAddress(member.loraAddress);
      if (memberAddr == normalized) {
        final name = member.displayName.trim();
        if (name.isNotEmpty) return name;
      }
    }
    return 'Node 0x$normalized';
  }

  String _sanitizeIncomingText(String raw) {
    var text = raw.trim();
    // Some firmwares prefix payloads with frame counters like `1|...`.
    text = text.replaceFirst(RegExp(r'^\d+\|'), '').trimLeft();
    // Keep emoji/non-ASCII content, only strip control characters.
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
    return text;
  }

  ({String? senderName, String text}) _splitSenderFromPayload(String payload) {
    var trimmed = payload.trim();
    if (trimmed.isEmpty) return (senderName: null, text: '');

    // Some firmwares prefix payloads with a numeric frame index, like `1|...`.
    // Strip a single leading `NNN|` so `1|CALLSIGN: hi` parses correctly.
    final numericPrefix = RegExp(r'^\d+\|').firstMatch(trimmed);
    if (numericPrefix != null) {
      trimmed = trimmed.substring(numericPrefix.end).trimLeft();
      if (trimmed.isEmpty) return (senderName: null, text: '');
    }

    // Preferred wire format: CALLSIGN: message
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

  ({int? groupId, String payload}) _extractGroupWirePayload(String payload) {
    final trimmed = payload.trim();
    final match = RegExp(r'^GROUP_MSG\|(\d+)\|(.+)$').firstMatch(trimmed);
    if (match == null) return (groupId: null, payload: payload);
    final parsedGroupId = int.tryParse(match.group(1) ?? '');
    final wrappedPayload = (match.group(2) ?? '').trim();
    if (parsedGroupId == null || wrappedPayload.isEmpty) {
      return (groupId: null, payload: payload);
    }
    return (groupId: parsedGroupId, payload: wrappedPayload);
  }

  Future<void> _fetchMessages() async {
    if (!_isConnected || deviceIp.trim().isEmpty) return;
    try {
      final uri = _buildUri('/api/status');
      final response = await http.get(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Connection timeout'),
      );
      if (response.statusCode != 200) return;

      final rawBody = _decodeResponseBody(response);
      dynamic decodedRaw;
      try {
        decodedRaw = jsonDecode(rawBody);
      } catch (_) {
        try {
          decodedRaw = jsonDecode(sanitizeJsonControlCharsInStrings(rawBody));
        } catch (e) {
          debugPrint('Failed to parse /api/status JSON: $e');
          return;
        }
      }
      if (decodedRaw is! Map<String, dynamic>) return;

      final traffic = _trafficFromStatus(decodedRaw);
      final lastRx = traffic['lastReceived']?.toString().trim() ?? '';
      
      if (lastRx.isEmpty) return;
      final currentReceivedCount = int.tryParse(
        (traffic['received'] ?? '').toString(),
      );
      final isDuplicate = lastRx == _lastRxText &&
          currentReceivedCount != null &&
          _lastRxReceivedCount != null &&
          currentReceivedCount == _lastRxReceivedCount;
      if (isDuplicate) return;

      if (lastRx.startsWith('HELLO|')) {
        _lastRxText = lastRx;
        _lastRxReceivedCount = currentReceivedCount;
        return;
      }
      if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(lastRx)) {
        _lastRxText = lastRx;
        _lastRxReceivedCount = currentReceivedCount;
        return;
      }

      _lastRxText = lastRx;
      _lastRxReceivedCount = currentReceivedCount;

      // Ignore raw group invite control frames; they are handled by background service.
      if (lastRx.startsWith('GROUP_INVITE|')) {
        return;
      }

      final tagged = RegExp(
        r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(lastRx);
      if (tagged != null) {
        final fromHex = _normalizeAddress(tagged.group(1) ?? '');
        final extracted = _extractGroupWirePayload(tagged.group(2) ?? '');
        if (extracted.groupId != null && extracted.groupId != widget.groupId) {
          return;
        }
        final parsed = _splitSenderFromPayload(extracted.payload);
        if (parsed.text.isEmpty) return;
        if (fromHex == _selfAddr) return;
        if (!_isGroupMemberAddress(fromHex)) return;

        if (!mounted) return;
        final fromContactId = await _findContactIdForAddress(fromHex);
        if (fromContactId != null) {
          await _persistGroupMessage(
            messageUuid: _newMessageUuid(),
            fromContactId: fromContactId,
            payload: parsed.text,
            status: MessageDeliveryStatus.none,
            isIncoming: true,
          );
        }

        setState(() {
          _messages.add(
            ChatMessage(
              text: parsed.text,
              sender: parsed.senderName ?? _senderLabelForAddress(fromHex),
              timestamp: DateTime.now(),
              isSystem: false,
            ),
          );
        });
        _scrollToBottom();
        return;
      }

      final relay = RegExp(
        r'^RELAY\|([0-9A-Fa-f]{4})\|(.+)$',
        caseSensitive: false,
      ).firstMatch(lastRx);
      if (relay != null) {
        final destHex = (relay.group(1) ?? '').toUpperCase();
        final extracted = _extractGroupWirePayload(relay.group(2) ?? '');
        if (extracted.groupId != null && extracted.groupId != widget.groupId) {
          return;
        }
        final parsed = _splitSenderFromPayload(extracted.payload);
        if (parsed.text.isEmpty) return;
        if (_targetHexes.isNotEmpty && !_targetHexes.contains(destHex)) return;
        if (!mounted) return;
        int? fromContactId;
        final relayDest = _normalizeAddress(destHex);
        if (relayDest.isNotEmpty) {
          fromContactId = await _findContactIdForAddress(relayDest);
        }
        if (fromContactId == null) {
          fromContactId = await LocalDatabaseService.instance.upsertContact(
            ContactRecord(
              loraAddress: '__GROUP_RELAY__$relayDest',
              displayName: parsed.senderName ?? 'Relay',
            ),
          );
        }
        await _persistGroupMessage(
          messageUuid: _newMessageUuid(),
          fromContactId: fromContactId,
          payload: parsed.text,
          status: MessageDeliveryStatus.none,
          isIncoming: true,
        );

        setState(() {
          _messages.add(
            ChatMessage(
              text: parsed.text,
              sender: parsed.senderName ?? 'Via relay -> 0x$destHex',
              timestamp: DateTime.now(),
              isSystem: false,
            ),
          );
        });
        _scrollToBottom();
        return;
      }

      // Some firmwares store plain payloads in lastReceived.
      // Accept only explicit "sender: message" payloads to avoid showing noise.
      final extracted = _extractGroupWirePayload(lastRx);
      if (extracted.groupId != null && extracted.groupId != widget.groupId) {
        return;
      }
      final plain = _splitSenderFromPayload(extracted.payload);
      final sender = plain.senderName?.trim() ?? '';
      if (plain.text.isEmpty || sender.isEmpty) return;
      if (_selfCallSign.isNotEmpty &&
          sender.toUpperCase() == _selfCallSign.toUpperCase()) {
        return;
      }

      if (!mounted) return;
      final fallbackFrom = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: '__GROUP_SENDER__${sender.toUpperCase()}',
          displayName: sender,
        ),
      );
      await _persistGroupMessage(
        messageUuid: _newMessageUuid(),
        fromContactId: fallbackFrom,
        payload: plain.text,
        status: MessageDeliveryStatus.none,
        isIncoming: true,
      );

      setState(() {
        _messages.add(
          ChatMessage(
            text: plain.text.toString(),
            sender: sender,
            timestamp: DateTime.now(),
            isSystem: false,
          ),
        );
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('Failed to fetch group messages: $e');
    }
  }
 
  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final host = deviceIp.trim();
    if (host.isEmpty) {
      throw Exception('Missing device IP');
    }
    final trimmedPort = devicePort.trim();
    final parsedPort = int.tryParse(trimmedPort);
    return Uri(
      scheme: 'http',
      host: host,
      port: parsedPort ?? 80,
      path: path,
      queryParameters: query,
    );
  }

  Future<void> _deliverGroupMessageToTargets({
    required String plainText,
    required int outgoingIndex,
    required List<String> sendTargets,
    required String groupUuid,
  }) async {
    final senderName = _selfCallSign.isNotEmpty ? _selfCallSign : 'Unknown';
    final payloadWithName = 'GROUP_MSG|$groupUuid|$senderName: $plainText';
    try {
      var ackedCount = 0;
      var noAckCount = 0;
      var failedCount = 0;

      for (final target in sendTargets) {
        try {
          final query = <String, String>{
            'msg': payloadWithName,
            'to': target,
            'groupUuid': groupUuid,
          };
          final uri = _buildUri('/send', query);
          final response = await http.get(uri).timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw Exception('Connection timeout'),
          );
          final body = _decodeResponseBody(response).trim();

          if (response.statusCode == 200) {
            ackedCount += 1;
          } else if (response.statusCode == 504 ||
              body.toUpperCase().contains('NO ACK') ||
              body.toUpperCase().contains('TIMEOUT')) {
            noAckCount += 1;
          } else {
            failedCount += 1;
          }
        } catch (_) {
          failedCount += 1;
          setState(() {
            _currentMessageLength = 0;
          });
        }
      }

      if (failedCount > 0) {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.failed);
      } else if (noAckCount > 0 && ackedCount == 0) {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.noAck);
      } else if (noAckCount > 0) {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.noAck);
      } else {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.acked);
      }
    } catch (_) {
      _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.failed);
      setState(() {
        _currentMessageLength = 0;
      });
      if (!mounted) return;
    }
  }

  Future<void> _sendMessage() async {
    final messageText = _messageController.text.trim();
    if (messageText.isEmpty) return;
    final String sendGroupUuid = widget.groupUuid;

    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to a mesh network first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final details = await LocalDatabaseService.instance.getGroupDetails(widget.groupId);
    if (!mounted || widget.groupUuid != sendGroupUuid) return;
    if (details == null || details.groupUuid != sendGroupUuid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load this group. Try opening it again.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final sendTargets = _resolveTargetsFromMembers(details.members);
    if (sendTargets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No valid group members found'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    int outgoingIndex = -1;
    setState(() {
      _groupMembers = details.members;
      _targetHexes = sendTargets;
      outgoingIndex = _messages.length;
      _messages.add(
        ChatMessage(
          text: messageText,
          sender: 'You',
          timestamp: DateTime.now(),
          isSystem: false,
          deliveryStatus: MessageDeliveryStatus.sending,
        ),
      );
    });
    final fromId = _selfContactId;
    if (fromId != null) {
      final uuid = _newMessageUuid();
      _messageUuidByIndex[outgoingIndex] = uuid;
      try {
        await _persistGroupMessage(
          messageUuid: uuid,
          fromContactId: fromId,
          payload: messageText,
          status: MessageDeliveryStatus.sending,
        );
      } catch (e) {
        debugPrint('Failed to persist outgoing group message: $e');
      }
    }
    _messageController.clear();
    setState(() {
      _currentMessageLength = 0;
    });
    _scrollToBottom();

    await _deliverGroupMessageToTargets(
      plainText: messageText,
      outgoingIndex: outgoingIndex,
      sendTargets: sendTargets,
      groupUuid: sendGroupUuid,
    );
    _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.acked);
  }

  void _updateOutgoingDeliveryStatus(int index, MessageDeliveryStatus status) {
    if (!mounted || index < 0 || index >= _messages.length) return;
    final current = _messages[index].deliveryStatus;
    // Prevent late async callbacks from downgrading a confirmed ACK.
    if (current == MessageDeliveryStatus.acked &&
        status != MessageDeliveryStatus.acked) {
      return;
    }
    setState(() {
      _messages[index] = _messages[index].copyWith(deliveryStatus: status);
    });
    final uuid = _messageUuidByIndex[index];
    if (uuid == null) return;
    unawaited(
      LocalDatabaseService.instance.updateMessageDeliveryStatus(
        messageUuid: uuid,
        status: _toDbDeliveryStatus(status),
      ),
    );
  }

  bool _canResendMessage(ChatMessage message) {
    return !message.isSystem &&
        message.sender == 'You' &&
        message.deliveryStatus == MessageDeliveryStatus.failed;
  }

  Future<void> _resendMessageAt(int index) async {
    if (index < 0 || index >= _messages.length) return;
    final message = _messages[index];
    if (!_canResendMessage(message)) return;

    if (!_isConnected) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to a mesh network first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final String sendGroupUuid = widget.groupUuid;
    final details = await LocalDatabaseService.instance.getGroupDetails(widget.groupId);
    if (!mounted || widget.groupUuid != sendGroupUuid) return;
    if (details == null || details.groupUuid != sendGroupUuid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load this group. Try opening it again.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final sendTargets = _resolveTargetsFromMembers(details.members);
    if (sendTargets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No valid group members found'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final messageText = message.text.trim();
    if (messageText.isEmpty) return;

    setState(() {
      _groupMembers = details.members;
      _targetHexes = sendTargets;
    });
    _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.sending);
    await _deliverGroupMessageToTargets(
      plainText: messageText,
      outgoingIndex: index,
      sendTargets: sendTargets,
      groupUuid: widget.groupUuid,
    );
  }

  Future<void> _confirmAndDeleteHistory() async {
    final loc = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.tr('deleteHistory')),
        content: Text(loc.tr('deleteHistoryMessage')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.tr('cancalButton')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(loc.tr('deleteHistoryButton')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final int groupId = widget.groupId;
    try {
      await LocalDatabaseService.instance.deleteGroupMessagesForGroup(
        groupId: groupId.toString(),
      );
      if (!mounted) return;
      setState(() {
        _messageUuidByIndex.clear();
        _messages
          ..clear()
          ..add(
            ChatMessage(
              text: 'Group chat ready. Messages will be sent to all members.',
              sender: 'System',
              timestamp: DateTime.now(),
              isSystem: true,
            ),
          );
      });
    } catch (e) {
      debugPrint('Failed to delete group chat history: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete history: $e')),
      );
    }
  }

  void _dismissKeyboard() {
    final currentFocus = FocusScope.of(context);
    if (!currentFocus.hasPrimaryFocus && currentFocus.focusedChild != null) {
      currentFocus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupTitle),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                _targetLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Group details',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupDetailsScreen(groupId: widget.groupId),
                ),
              );
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
            onSelected: (value) {
              if (value == 'delete_history') {
                unawaited(_confirmAndDeleteHistory());
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                value: 'delete_history',
                child: Text(AppLocalizations.of(context).tr('deleteHistory')),
              ),
            ],
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissKeyboard,
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet',
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final message = _messages[index];
                        if (!_canResendMessage(message)) {
                          return ChatBubble(message: message);
                        }
                        return GestureDetector(
                          onLongPress: () {
                            showDialog<void>(
                              context: context,
                              builder: (_) => IosStyleContextMenu(
                                actions: [
                                  ContextMenuAndroid(
                                    icon: Icons.refresh,
                                    label: AppLocalizations.of(context).tr('resend'),
                                    onTap: () => unawaited(_resendMessageAt(index)),
                                  ),
                                ],
                                child: ChatBubble(message: message),
                              ),
                            );
                          },
                          child: ChatBubble(message: message),
                        );
                      },
                    ),
            ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 6,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceVariant
                                    .withOpacity(0.9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              child: TextField(
                                controller: _messageController,
                                decoration: const InputDecoration(
                                  hintText: 'Type a message...',
                                  border: InputBorder.none,
                                  counterText: '',
                                ),
                                maxLines: 4,
                                minLines: 1,
                                maxLength: _maxMessageLength,
                                textCapitalization: TextCapitalization.sentences,
                                onChanged: (value) {
                                  setState(() {
                                    _currentMessageLength =
                                        value.length.clamp(0, _maxMessageLength);
                                  });
                                },
                                onSubmitted: (_) => _sendMessage(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            height: 44,
                            width: 44,
                            child: ElevatedButton(
                              onPressed: _sendMessage,
                              style: ElevatedButton.styleFrom(
                                padding: EdgeInsets.zero,
                                shape: const CircleBorder(),
                                elevation: 1,
                              ),
                              child: Image.asset(
                                'assets/icons/send.png',
                                width: 22,
                                height: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          '$_currentMessageLength / $_maxMessageLength',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
