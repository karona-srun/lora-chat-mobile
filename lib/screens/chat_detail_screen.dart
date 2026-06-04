import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:context_menu_android/features/context_menu/data/models/context_menu.dart';
import 'package:context_menu_android/features/context_menu/presentation/widget/ios_style_context_menu.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../services/local_database_service.dart';
import '../services/chat_unread_dot_service.dart';
import '../services/message_background_service.dart';
import '../utils/gps_message_utils.dart';
import '../utils/json_string_sanitize.dart';
import '../widgets/chat_bubble.dart';

class ChatDetailScreen extends StatefulWidget {
  const ChatDetailScreen({
    super.key,
    required this.title,
    this.targetNodeId,
    this.selfContactId,
  });

  final String title;
  final String? targetNodeId;
  final String? selfContactId;
  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen>
    with WidgetsBindingObserver {
  static const String _saveDatabaseLocallyPrefKey = 'save_database_locally';
  static const String _powerModePrefKey = 'power_mode';
  static const Duration _messagePollInterval = Duration(milliseconds: 800);
  static const Duration _statusPollTimeout = Duration(seconds: 2);
  static const Duration _sendTimeout = Duration(seconds: 12);
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  bool _saveDatabaseLocallyEnabled = false;
  String _powerMode = 'powerModeBalanced';

  int get _maxMessageLength => _powerMode == 'powerModeBalanced' ? 100 : 50;
  final List<ChatMessage> _messages = [];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  Timer? _dbMessageSyncTimer;
  int _currentMessageLength = 0;
  String _lastRxText = '';
  int? _lastRxReceivedCount;
  int? _lastDbSyncedReceivedCount;
  String? _targetHex;
  String? _selfContactId;
  String? _targetContactId;
  final Map<int, String> _messageUuidByIndex = <int, String>{};
  bool _fetchMessagesInFlight = false;
  bool _suspendStatusPoll = false;
  bool _dbMessageSyncInFlight = false;
  int _lastObservedMessagesChangedAt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Add a welcome message
    _messages.add(
      ChatMessage(
        text: 'Connect to a LoRa node (saved IP/port), then send via /send. ',
        sender: 'System',
        timestamp: DateTime.now(),
        isSystem: true,
      ),
    );
    // Load saved connection settings from shared preferences
    _loadConnectionPrefs();

    // Start polling for incoming messages
    _messagePollTimer = Timer.periodic(
      _messagePollInterval,
      (_) => _fetchMessages(),
    );
    _dbMessageSyncTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_refreshPersistedMessagesIfChanged()),
    );
    // And fetch once immediately
    _fetchMessages();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tid = widget.targetNodeId;
      if (tid != null && tid.isNotEmpty) {
        unawaited(
          ChatUnreadDotService.clearDirectUnread(
            ChatUnreadDotService.normalizeAddr(tid),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messagePollTimer?.cancel();
    _dbMessageSyncTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_saveDatabaseLocallyEnabled) return;
    unawaited(_initializeDirectChatPersistence());
  }

  Future<void> _loadConnectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();
      final saveDbEnabled = prefs.getBool(_saveDatabaseLocallyPrefKey) ?? false;
      final storedPowerMode = prefs.getString(_powerModePrefKey);
      final lastReceivedText =
          prefs.getString('message_last_received_text')?.trim() ?? '';
      final lastReceivedCount = prefs.getInt('message_last_received_count');

      if (!mounted) return;

      setState(() {
        deviceIp = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        devicePort = (savedPort != null && savedPort.isNotEmpty)
            ? savedPort
            : '';
        _isConnected = deviceIp.isNotEmpty;
        _saveDatabaseLocallyEnabled = saveDbEnabled;
        if (storedPowerMode != null && storedPowerMode.isNotEmpty) {
          _powerMode = storedPowerMode;
        }
        _lastRxText = lastReceivedText;
        _lastRxReceivedCount = lastReceivedCount;
        _currentMessageLength = _currentMessageLength.clamp(
          0,
          _maxMessageLength,
        );
      });
      await _initializeDirectChatPersistence();
    } catch (e) {
      debugPrint('Failed to load connection prefs: $e');
    }
  }

  Future<void> _refreshPersistedMessagesIfChanged() async {
    if (!mounted) return;
    if (_dbMessageSyncInFlight) return;
    _dbMessageSyncInFlight = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final changedAt =
          prefs.getInt(MessageBackgroundService.messageChangedAtMsKey) ?? 0;
      if (changedAt <= _lastObservedMessagesChangedAt) return;
      _lastObservedMessagesChangedAt = changedAt;
      if (_saveDatabaseLocallyEnabled &&
          _selfContactId != null &&
          _targetContactId != null) {
        await _loadDirectMessagesFromDb();
      } else {
        await _fetchMessages();
      }
      final tid = widget.targetNodeId;
      if (tid != null && tid.isNotEmpty) {
        await ChatUnreadDotService.clearDirectUnread(
          ChatUnreadDotService.normalizeAddr(tid),
        );
      }
    } catch (e) {
      debugPrint('Failed to refresh persisted direct messages: $e');
    } finally {
      _dbMessageSyncInFlight = false;
    }
  }

  String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  String _newMessageUuid() {
    return 'dm_${DateTime.now().microsecondsSinceEpoch}_${_messages.length}';
  }

  Future<int?> _resolveTargetContactIdFromDb({
    required String normalizedTarget,
  }) async {
    final contacts = await LocalDatabaseService.instance.listContacts();
    for (final contact in contacts) {
      if (_normalizeAddress(contact.loraAddress) == normalizedTarget) {
        return contact.id;
      }
    }
    final titleUpper = widget.title.trim().toUpperCase();
    if (titleUpper.isEmpty) return null;
    for (final contact in contacts) {
      if (contact.displayName.trim().toUpperCase() == titleUpper) {
        return contact.id;
      }
    }
    return null;
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

  MessageDeliveryStatus _toLoadedUiDeliveryStatus(
    MessageRecord record, {
    required bool isOutgoing,
  }) {
    if (isOutgoing && record.deliveryStatus == DeliveryStatus.pending) {
      return MessageDeliveryStatus.failed;
    }
    return _toUiDeliveryStatus(record.deliveryStatus);
  }

  Future<void> _initializeDirectChatPersistence() async {
    if (!_saveDatabaseLocallyEnabled) return;
    final target = _targetHex ?? _resolveTargetHex();
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCallSign = (prefs.getString('callSign') ?? '').trim();
      final myAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );
      final normalizedTarget = _normalizeAddress(target ?? '');
      if (normalizedTarget.isEmpty) return;
      _targetHex = normalizedTarget;

      debugPrint('myAddr: $myAddr');
      debugPrint('widget.selfContactId: ${widget.selfContactId}');

      final selfId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: myAddr.isNotEmpty ? myAddr : '__SELF__',
          displayName: myCallSign.isNotEmpty ? myCallSign : 'You',
        ),
      );
      final existingTargetId = await _resolveTargetContactIdFromDb(
        normalizedTarget: normalizedTarget,
      );
      final targetId =
          existingTargetId ??
          await LocalDatabaseService.instance.upsertContact(
            ContactRecord(
              loraAddress: normalizedTarget,
              displayName: widget.title.trim().isNotEmpty
                  ? widget.title.trim()
                  : '0x$normalizedTarget',
            ),
          );
      setState(() {
        _selfContactId = selfId.toString();
        _targetContactId = targetId.toString();
      });

      await _loadDirectMessagesFromDb();
    } catch (e) {
      debugPrint('Failed to initialize direct chat persistence: $e');
    }
  }

  Future<void> _loadDirectMessagesFromDb() async {
    final selfId = _selfContactId;
    final targetId = _targetContactId;
    if (selfId == null || targetId == null) return;
    debugPrint('_loadDirectMessagesFromDb()');
    try {
      final records = await LocalDatabaseService.instance.listDirectMessages(
        contactA: selfId.toString(),
        contactB: targetId.toString(),
      );

      debugPrint('selfId: $selfId');
      debugPrint('targetId: $targetId');
      debugPrint('records: ${records.length}');

      debugPrint(
        'records: ${records.map((record) => record.toMap()).toList()}',
      );

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
              final isOutgoing =
                  record.fromContactId == selfId.toString() &&
                  record.toContactId == targetId.toString();
              return ChatMessage(
                text: record.payload,
                sender: isOutgoing ? 'You' : widget.title,
                timestamp: _parseMessageTime(record),
                isSystem: false,
                deliveryStatus: _toLoadedUiDeliveryStatus(
                  record,
                  isOutgoing: isOutgoing,
                ),
              );
            }),
          );
        if (_messages.isEmpty) {
          _messages.add(
            ChatMessage(
              text:
                  'Connect to a LoRa node (saved IP/port), then send via /send. ',
              sender: 'System',
              timestamp: DateTime.now(),
              isSystem: true,
            ),
          );
        }
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('Failed to load direct messages: $e');
    }
  }

  Future<void> _persistDirectMessage({
    required String messageUuid,
    required String fromContactId,
    required String toContactId,
    required String payload,
    required MessageDeliveryStatus status,
    bool isIncoming = false,
  }) async {
    if (!_saveDatabaseLocallyEnabled) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await LocalDatabaseService.instance.insertMessage(
      MessageRecord(
        messageUuid: messageUuid,
        chatType: ChatType.direct,
        fromContactId: fromContactId.toString(),
        toContactId: toContactId.toString(),
        payload: payload,
        deliveryStatus: _toDbDeliveryStatus(status),
        sentAt: isIncoming ? null : now,
        receivedAt: isIncoming ? now : null,
      ),
    );
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

  String? _resolveTargetHex() {
    final targetId = widget.targetNodeId?.trim();
    if (targetId != null && targetId.isNotEmpty) {
      var t = targetId.toUpperCase();
      if (t.startsWith('0X')) t = t.substring(2);
      t = t.replaceAll(RegExp(r'[\s:-]'), '');
      if (t.length == 2) return '00${t.padLeft(2, '0')}';
      if (t.length == 4) return t.padLeft(4, '0');
    }
    final fromTitle = RegExp(
      r'0x([0-9A-Fa-f]{2,4})',
      caseSensitive: false,
    ).firstMatch(widget.title);
    if (fromTitle != null) {
      var hex = (fromTitle.group(1) ?? '').toUpperCase();
      if (hex.length == 2) hex = '00$hex';
      if (hex.length == 4) return hex;
    }
    return null;
  }

  bool _matchesTarget(String fromHex) {
    final target = _targetHex;
    if (target == null || target.isEmpty) return true;
    return fromHex.toUpperCase() == target.toUpperCase();
  }

  Map<String, dynamic> _trafficFromStatus(Map<String, dynamic> data) {
    final traffic = data['traffic'];
    if (traffic is Map<String, dynamic>) return traffic;
    return data;
  }

  /// Device JSON may include raw LoRa payloads; strict UTF-8 on [http.Response.body] throws.
  String _decodeResponseBody(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  String _sanitizeIncomingText(String raw) {
    var text = raw.trim();
    // Some firmwares prefix payloads with frame counters like `1|...`.
    text = text.replaceFirst(RegExp(r'^\d+\|'), '').trimLeft();
    // Preserve UTF-8 message content (Khmer, emoji, etc.); remove only wire noise.
    text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');
    return text;
  }

  String _sanitizeIncomingTextRelay(String raw) {
    var text = raw.trim();
    // Handle nested wrapper payloads:
    // - MSG|SRC|DEST|message
    // - MSG2|ADDR|SRC|DEST|message
    // - RELAY|DEST|MSG|SRC|DEST|message
    final nestedMsg = RegExp(
      r'^(?:RELAY\|[0-9A-Fa-f]{2,4}\|)?MSG\|[0-9A-Fa-f]{2,4}\|[0-9A-Fa-f]{2,4}\|?MSG2\|[0-9A-Fa-f]{2,4}\|[0-9A-Fa-f]{2,4}\|[0-9A-Fa-f]{2,4}\|?(.+)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (nestedMsg != null) {
      text = (nestedMsg.group(1) ?? '').trim();
    }
    return text;
  }

  /// Pads node ids to 4 hex digits for comparison with [_targetHex].
  String _normalizeNodeHex(String hex) {
    var h = hex.toUpperCase();
    if (h.length == 2) return '00$h';
    if (h.length == 4) return h;
    return h.length < 4 ? h.padLeft(4, '0') : h.substring(0, 4);
  }

  Map<String, dynamic>? _tryDecodeStatusJson(String rawBody) {
    dynamic decodedRaw;
    try {
      decodedRaw = jsonDecode(rawBody);
    } catch (_) {
      try {
        decodedRaw = jsonDecode(sanitizeJsonControlCharsInStrings(rawBody));
      } catch (e) {
        debugPrint('Failed to parse /api/status JSON: $e');
        return null;
      }
    }
    if (decodedRaw is! Map<String, dynamic>) return null;
    return decodedRaw;
  }

  bool _isIgnoredStatusNoise(String lastRx) {
    if (lastRx.startsWith('HELLO|')) return true;
    if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(lastRx)) {
      return true;
    }
    return false;
  }

  bool _isGroupTrafficFrame(String payload) {
    final text = payload.trim().toUpperCase();
    if (text.isEmpty) return false;
    return text.startsWith('GROUP_MSG|') ||
        text.contains('|GROUP_MSG|') ||
        text.contains('GROUP_INVITE|') ||
        text.contains('GROUP_REMOVE|') ||
        text.contains('GROUP_LEAVE|') ||
        text.contains('GROUP_MEMBER_REMOVE|');
  }

  Future<void> _appendIncomingDirectMessage({
    required String text,
    required String sender,
  }) async {
    if (!mounted) return;
    final selfId = _selfContactId;
    final targetId = _targetContactId;
    final fromId = int.tryParse(targetId ?? '');
    final toId = int.tryParse(selfId ?? '');
    if (fromId != null && toId != null) {
      final isDup = await LocalDatabaseService.instance
          .hasRecentDuplicateIncomingMessage(
            chatType: ChatType.direct,
            fromContactId: fromId,
            toContactId: toId,
            payload: text,
          );
      if (isDup) return;
    }
    if (selfId != null && targetId != null) {
      final msg = text.toString().replaceAll("%20", " ");
      await _persistDirectMessage(
        messageUuid: _newMessageUuid(),
        fromContactId: targetId.toString(),
        toContactId: selfId.toString(),
        payload: msg,
        status: MessageDeliveryStatus.none,
        isIncoming: true,
      );
    }
    if (!mounted) return;
    setState(() {
      final msg = text.toString().replaceAll("%20", " ");
      _messages.add(
        ChatMessage(
          text: msg,
          sender: sender,
          timestamp: DateTime.now(),
          isSystem: false,
        ),
      );
    });
    _scrollToBottom();
  }

  static final RegExp _reFromTagged = RegExp(
    r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
    caseSensitive: false,
  );
  static final RegExp _reRelayFull = RegExp(
    r'^RELAY\|([0-9A-Fa-f]{4})\|([0-9A-Fa-f]{3})\|([0-9A-Fa-f]{4})\|([0-9A-Fa-f]{4})\|(.+)$',
    caseSensitive: false,
  );
  static final RegExp _reMsgPipe = RegExp(
    r'^MSG\|([0-9A-Fa-f]{2,4})\|([0-9A-Fa-f]{2,4})\|(.+)$',
    caseSensitive: false,
  );
  static final RegExp _reMsgPipe2 = RegExp(
    r'^MSG2\|([0-9A-Fa-f]{2,4})\|([0-9A-Fa-f]{2,4})\|([0-9A-Fa-f]{2,4})\|(.+)$',
    caseSensitive: false,
  );

  void _schedulePostSendPolls() {
    const delays = <Duration>[
      Duration(milliseconds: 250),
      Duration(milliseconds: 1200),
      Duration(milliseconds: 2500),
    ];
    for (final delay in delays) {
      Future<void>.delayed(delay, () {
        if (!mounted) return;
        unawaited(_fetchMessages());
      });
    }
  }

  Future<void> _fetchMessages() async {
    if (!_isConnected || deviceIp.trim().isEmpty) return;
    if (_suspendStatusPoll) return;
    if (_fetchMessagesInFlight) return;
    _fetchMessagesInFlight = true;
    try {
      final uri = _buildUri('/api/status');
      final response = await http
          .get(uri)
          .timeout(
            _statusPollTimeout,
            onTimeout: () => throw TimeoutException('/api/status'),
          );
      if (response.statusCode != 200) return;

      final rawBody = _decodeResponseBody(response);
      final decoded = _tryDecodeStatusJson(rawBody);
      if (decoded == null) return;

      final traffic = _trafficFromStatus(decoded);

      final lastRx = traffic['lastReceived']?.toString().trim() ?? '';
      if (lastRx.isEmpty) return;
      final currentReceivedCount = int.tryParse(
        (traffic['received'] ?? '').toString(),
      );
      if (_saveDatabaseLocallyEnabled &&
          currentReceivedCount != null &&
          currentReceivedCount != _lastDbSyncedReceivedCount) {
        _lastDbSyncedReceivedCount = currentReceivedCount;
        await _loadDirectMessagesFromDb();
      }
      final isDuplicateByTextAndCount =
          lastRx == _lastRxText &&
          currentReceivedCount != null &&
          _lastRxReceivedCount != null &&
          currentReceivedCount == _lastRxReceivedCount;
      if (isDuplicateByTextAndCount) return;

      if (_isIgnoredStatusNoise(lastRx)) {
        _lastRxText = lastRx;
        _lastRxReceivedCount = currentReceivedCount;
        return;
      }

      _lastRxText = lastRx;
      _lastRxReceivedCount = currentReceivedCount;
      if (_isGroupTrafficFrame(lastRx)) return;

      final tagged = _reFromTagged.firstMatch(lastRx);
      if (tagged != null) {
        var fromHex = (tagged.group(1) ?? '').toUpperCase();
        final taggedPayload = (tagged.group(2) ?? '').trim();
        if (_isGroupTrafficFrame(taggedPayload)) return;
        final text = _sanitizeIncomingText(taggedPayload);
        if (text.isEmpty) return;
        if (fromHex.length == 2) fromHex = '00$fromHex';
        if (fromHex.length == 4 && !_matchesTarget(fromHex)) return;

        await _appendIncomingDirectMessage(
          text: text,
          sender: 'Node 0x$fromHex',
        );
        return;
      }

      // RELAY|DEST|…|payload — payload is the last group (after four metadata fields).
      final relay = _reRelayFull.firstMatch(lastRx);
      if (relay != null) {
        final relayPayload = (relay.group(5) ?? '').trim();
        if (_isGroupTrafficFrame(relayPayload)) return;
        final destHex = (relay.group(1) ?? '').toUpperCase();
        final text = _sanitizeIncomingTextRelay(relayPayload);
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null && destHex.toUpperCase() != target.toUpperCase()) {
          return;
        }

        await _appendIncomingDirectMessage(
          text: text,
          sender: 'Via relay -> 0x$destHex',
        );
        return;
      }

      // MSG2|SRC|DEST|SRC2|DEST2|payload
      final msgRelay2 = _reMsgPipe2.firstMatch(lastRx);
      if (msgRelay2 != null) {
        final msgPayload = (msgRelay2.group(6) ?? '').trim();
        if (_isGroupTrafficFrame(msgPayload)) return;
        final srcNorm = _normalizeNodeHex(
          (msgRelay2.group(1) ?? '').toUpperCase(),
        );
        final destNorm = _normalizeNodeHex(
          (msgRelay2.group(2) ?? '').toUpperCase(),
        );
        final src2Norm = _normalizeNodeHex(
          (msgRelay2.group(3) ?? '').toUpperCase(),
        );
        final dest2Norm = _normalizeNodeHex(
          (msgRelay2.group(4) ?? '').toUpperCase(),
        );
        final text = _sanitizeIncomingTextRelay(msgPayload);
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null && destNorm.toUpperCase() != target.toUpperCase()) {
          return;
        }
        await _appendIncomingDirectMessage(
          text: text,
          sender:
              'Via relay $srcNorm -> 0x$destNorm -> 0x$src2Norm -> 0x$dest2Norm',
        );
        return;
      }

      // MSG|SRC|DEST|payload
      final msgRelay = _reMsgPipe.firstMatch(lastRx);
      if (msgRelay != null) {
        final msgPayload = (msgRelay.group(3) ?? '').trim();
        if (_isGroupTrafficFrame(msgPayload)) return;
        final srcNorm = _normalizeNodeHex(
          (msgRelay.group(1) ?? '').toUpperCase(),
        );
        final destNorm = _normalizeNodeHex(
          (msgRelay.group(2) ?? '').toUpperCase(),
        );
        final text = _sanitizeIncomingTextRelay(msgPayload);
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null && destNorm.toUpperCase() != target.toUpperCase()) {
          return;
        }

        await _appendIncomingDirectMessage(
          text: text,
          sender: 'Via relay $srcNorm -> 0x$destNorm',
        );
        return;
      }

      // Plain LoRa payload (firmware stores raw `rc.data` in lastReceived).
      // There is no sender/recipient in this shape, but `lastReceived` is
      // global for the node — attributing it to the currently open direct chat
      // would show other peers' traffic in the wrong thread. Use tagged / MSG /
      // RELAY branches above when the firmware includes addresses.
      final plainText = _sanitizeIncomingText(lastRx);
      if (plainText.isEmpty) return;
      return;
    } catch (e) {
      debugPrint('Failed to fetch messages: $e');
    } finally {
      _fetchMessagesInFlight = false;
    }
  }

  Future<void> _sendMessage() async {
    final messageText = _messageController.text.trim();
    await _sendOutgoingText(messageText);
  }

  Future<int> _appendOutgoingDirectMessage(
    String messageText, {
    MessageDeliveryStatus status = MessageDeliveryStatus.sending,
    String persistErrorLabel = 'outgoing direct message',
  }) async {
    var outgoingIndex = -1;
    setState(() {
      outgoingIndex = _messages.length;
      _messages.add(
        ChatMessage(
          text: messageText,
          sender: 'You',
          timestamp: DateTime.now(),
          isSystem: false,
          deliveryStatus: status,
        ),
      );
    });

    final selfId = _selfContactId;
    final targetId = _targetContactId;
    if (selfId != null && targetId != null) {
      final uuid = _newMessageUuid();
      _messageUuidByIndex[outgoingIndex] = uuid;
      try {
        await _persistDirectMessage(
          messageUuid: uuid,
          fromContactId: selfId.toString(),
          toContactId: targetId.toString(),
          payload: messageText,
          status: status,
        );
      } catch (e) {
        debugPrint('Failed to persist $persistErrorLabel: $e');
      }
    }

    _scrollToBottom();
    return outgoingIndex;
  }

  Map<String, String> _buildGpsQuery({bool useRelay = false}) {
    final query = <String, String>{};
    if (useRelay) {
      query['relay'] = '1';
    }
    final target = _targetHex;
    if (target != null && target.isNotEmpty) {
      query['to'] = target;
    }
    return query;
  }

  Future<void> _sendGPS({bool useRelay = false}) async {
    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to a mesh network first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    _suspendStatusPoll = true;
    try {
      final uri = _buildUri('/gps', _buildGpsQuery(useRelay: useRelay));
      final response = await http
          .get(uri)
          .timeout(
            _sendTimeout,
            onTimeout: () => throw TimeoutException('/gps'),
          );
      final body = _decodeResponseBody(response).trim();
      final preview = GpsMessageUtils.previewBody(body);
      final gpsMessage = GpsMessageUtils.formatResponseMessage(preview);
      final deliveryStatus = GpsMessageUtils.deliveryStatusFromResponse(
        response,
        body,
      );

      await _appendOutgoingDirectMessage(
        gpsMessage.isEmpty ? GpsMessageUtils.fallbackMessage : gpsMessage,
        status: deliveryStatus,
        persistErrorLabel: 'outgoing GPS message',
      );

      if (!mounted) return;
      if (deliveryStatus == MessageDeliveryStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(preview.isEmpty ? 'GPS request failed' : preview),
            backgroundColor: Colors.red,
          ),
        );
      }
    } on TimeoutException catch (_) {
      await _appendOutgoingDirectMessage(
        GpsMessageUtils.fallbackMessage,
        status: MessageDeliveryStatus.noAck,
        persistErrorLabel: 'timed out GPS message',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('GPS request timed out'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      await _appendOutgoingDirectMessage(
        GpsMessageUtils.fallbackMessage,
        status: MessageDeliveryStatus.failed,
        persistErrorLabel: 'failed GPS message',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send GPS: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _suspendStatusPoll = false;
      _schedulePostSendPolls();
    }
  }

  Future<void> _sendOutgoingText(
    String messageText, {
    bool clearComposer = true,
  }) async {
    if (messageText.isEmpty) return;

    if (!_isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to a mesh network first'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    int outgoingIndex = -1;
    setState(() {
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
      if (clearComposer) {
        _currentMessageLength = 0;
      }
    });
    final selfId = _selfContactId;
    final targetId = _targetContactId;

    debugPrint('selfId: $selfId');
    if (selfId != null && targetId != null) {
      final uuid = _newMessageUuid();
      _messageUuidByIndex[outgoingIndex] = uuid;
      try {
        await _persistDirectMessage(
          messageUuid: uuid,
          fromContactId: selfId.toString(),
          toContactId: targetId.toString(),
          payload: messageText,
          status: MessageDeliveryStatus.sending,
        );
      } catch (e) {
        debugPrint('Failed to persist outgoing direct message: $e');
      }
    }
    if (clearComposer) {
      _messageController.clear();
    }
    _scrollToBottom();

    _suspendStatusPoll = true;
    try {
      final target = _targetHex;
      // Firmware handleSend: /send?msg=... optional &to=AABB.
      final query = <String, String>{'msg': messageText};
      if (target != null && target.isNotEmpty) {
        query['to'] = target;
      }

      final uri = _buildUri('/send', query);
      final response = await http
          .get(uri)
          .timeout(
            _sendTimeout,
            onTimeout: () => throw TimeoutException('/send'),
          );
      final body = _decodeResponseBody(response).trim();

      if (response.statusCode == 200) {
        _updateOutgoingDeliveryStatus(
          outgoingIndex,
          MessageDeliveryStatus.acked,
        );
      } else if (response.statusCode == 504 ||
          body.toUpperCase().contains('NO ACK') ||
          body.toUpperCase().contains('TIMEOUT')) {
        _updateOutgoingDeliveryStatus(
          outgoingIndex,
          MessageDeliveryStatus.noAck,
        );
      } else {
        _updateOutgoingDeliveryStatus(
          outgoingIndex,
          MessageDeliveryStatus.failed,
        );
        throw Exception('Server returned: ${response.statusCode} - $body');
      }
    } on TimeoutException catch (_) {
      _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.noAck);
    } catch (e) {
      _updateOutgoingDeliveryStatus(
        outgoingIndex,
        MessageDeliveryStatus.failed,
      );
      if (!mounted) return;
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(
      //     content: Text('Failed to send message: ${e.toString()}'),
      //     backgroundColor: Colors.red,
      //   ),
      // );
    } finally {
      _suspendStatusPoll = false;
      _schedulePostSendPolls();
    }
  }

  void _updateOutgoingDeliveryStatus(int index, MessageDeliveryStatus status) {
    final uuid = _messageUuidByIndex[index];
    var shouldPersist = uuid != null;

    if (mounted && index >= 0 && index < _messages.length) {
      final current = _messages[index].deliveryStatus;
      // Prevent late async callbacks from downgrading a confirmed ACK.
      if (current == MessageDeliveryStatus.acked &&
          status != MessageDeliveryStatus.acked) {
        shouldPersist = false;
      } else {
        setState(() {
          _messages[index] = _messages[index].copyWith(deliveryStatus: status);
        });
      }
    }

    if (!shouldPersist || uuid == null) return;
    unawaited(
      LocalDatabaseService.instance.updateMessageDeliveryStatus(
        messageUuid: uuid,
        status: _toDbDeliveryStatus(status),
      ),
    );
  }

  bool _canResendMessage(ChatMessage message) {
    if (message.isSystem || message.sender != 'You') return false;
    final s = message.deliveryStatus;
    return s == MessageDeliveryStatus.failed ||
        s == MessageDeliveryStatus.noAck;
  }

  Future<void> _copyMessageText(ChatMessage message) async {
    final text = message.text;
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(MaterialLocalizations.of(context).copyButtonLabel),
        duration: const Duration(seconds: 1),
      ),
    );
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

    final messageText = message.text.trim();
    if (messageText.isEmpty) return;

    _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.sending);

    _suspendStatusPoll = true;
    try {
      final target = _targetHex;
      final query = <String, String>{'msg': messageText};
      if (target != null && target.isNotEmpty) {
        query['to'] = target;
      }

      final uri = _buildUri('/send', query);
      final response = await http
          .get(uri)
          .timeout(
            _sendTimeout,
            onTimeout: () => throw TimeoutException('/send'),
          );
      final body = _decodeResponseBody(response).trim();

      if (response.statusCode == 200) {
        _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.acked);
      } else if (response.statusCode == 504 ||
          body.toUpperCase().contains('NO ACK') ||
          body.toUpperCase().contains('TIMEOUT')) {
        _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.noAck);
      } else {
        _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.failed);
      }
    } on TimeoutException catch (_) {
      _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.noAck);
    } catch (_) {
      _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.failed);
    } finally {
      _suspendStatusPoll = false;
      _schedulePostSendPolls();
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

    final selfId = _selfContactId;
    final targetId = _targetContactId;
    try {
      if (selfId != null && targetId != null) {
        await LocalDatabaseService.instance.deleteDirectMessagesBetween(
          contactA: selfId.toString(),
          contactB: targetId.toString(),
        );
      }
      if (!mounted) return;
      setState(() {
        _messageUuidByIndex.clear();
        _messages
          ..clear()
          ..add(
            ChatMessage(
              text:
                  'Connect to a LoRa node (saved IP/port), then send via /send. ',
              sender: 'System',
              timestamp: DateTime.now(),
              isSystem: true,
            ),
          );
      });
    } catch (e) {
      debugPrint('Failed to delete chat history: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete history: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetLabel = _targetHex == null ? 'Device default' : '0x$_targetHex';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        elevation: 0,
        actions: [
          Row(
            children: [
              Icon(
                Icons.wifi_tethering,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 3),
              Text(
                targetLabel,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
              ),
            ],
          ),
          const SizedBox(width: 5),
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
          const SizedBox(width: 5),
        ],
      ),
      body: Column(
        children: [
          // Messages List
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No messages yet',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final bubble = ChatBubble(message: message);
                      return GestureDetector(
                        onLongPress: () {
                          showDialog<void>(
                            context: context,
                            builder: (_) => IosStyleContextMenu(
                              actions: [
                                ContextMenuAndroid(
                                  icon: Icons.copy,
                                  label: MaterialLocalizations.of(
                                    context,
                                  ).copyButtonLabel,
                                  onTap: () =>
                                      unawaited(_copyMessageText(message)),
                                ),
                                if (_canResendMessage(message))
                                  ContextMenuAndroid(
                                    icon: Icons.refresh,
                                    label: AppLocalizations.of(
                                      context,
                                    ).tr('resend'),
                                    onTap: () =>
                                        unawaited(_resendMessageAt(index)),
                                  ),
                              ],
                              child: bubble,
                            ),
                          );
                        },
                        child: bubble,
                      );
                    },
                  ),
          ),
          // Message Input
          Container(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: _sendGPS,
                          icon: const Icon(Icons.online_prediction_outlined),
                        ),
                        // Message input
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceVariant.withOpacity(0.9),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: TextField(
                              controller: _messageController,
                              decoration: const InputDecoration(
                                hintText: 'Type a message…',
                                border: InputBorder.none,
                                counterText: '',
                              ),
                              maxLines: 4,
                              minLines: 1,
                              maxLength: _maxMessageLength,
                              textCapitalization: TextCapitalization.sentences,
                              onChanged: (value) {
                                setState(() {
                                  _currentMessageLength = value.length.clamp(
                                    0,
                                    _maxMessageLength,
                                  );
                                });
                              },
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Send button
                        SizedBox(
                          height: 44,
                          width: 44,
                          child: ElevatedButton(
                            onPressed: _sendMessage,
                            style: ElevatedButton.styleFrom(
                              padding: EdgeInsets.all(0),
                              shape: const CircleBorder(),
                              elevation: 0,
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
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _targetHex ??= _resolveTargetHex();
    unawaited(_initializeDirectChatPersistence());
  }
}
