import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:context_menu_android/features/context_menu/data/models/context_menu.dart';
import 'package:context_menu_android/features/context_menu/presentation/widget/ios_style_context_menu.dart';
import '../l10n/app_localizations.dart';
import '../models/chat_message.dart';
import '../services/local_database_service.dart';
import '../utils/json_string_sanitize.dart';
import '../widgets/chat_bubble.dart';

class ChatDetailScreen extends StatefulWidget {
  const ChatDetailScreen({
    super.key,
    required this.title,
    this.targetNodeId,
  });

  final String title;
  final String? targetNodeId;

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  static const String _saveDatabaseLocallyPrefKey = 'save_database_locally';
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  bool _saveDatabaseLocallyEnabled = false;
  final List<ChatMessage> _messages = [];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  int _currentMessageLength = 0;
  String _lastRxText = '';
  String? _targetHex;
  int? _selfContactId;
  int? _targetContactId;
  final Map<int, String> _messageUuidByIndex = <int, String>{};

  @override
  void initState() {
    super.initState();
    // Add a welcome message
    _messages.add(ChatMessage(
      text:
          'Connect to a LoRa node (saved IP/port), then send via /send. ',
      sender: 'System',
      timestamp: DateTime.now(),
      isSystem: true,
    ));

    // Load saved connection settings from shared preferences
    _loadConnectionPrefs();

    // Start polling for incoming messages
    _messagePollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _fetchMessages(),
    );
    // And fetch once immediately
    _fetchMessages();
  }

  @override
  void dispose() {
    _messagePollTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadConnectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();
      final saveDbEnabled = prefs.getBool(_saveDatabaseLocallyPrefKey) ?? false;

      if (!mounted) return;

      setState(() {
        deviceIp =
            (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        devicePort =
            (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';
        _isConnected = deviceIp.isNotEmpty;
        _saveDatabaseLocallyEnabled = saveDbEnabled;
      });
      await _initializeDirectChatPersistence();
    } catch (e) {
      debugPrint('Failed to load connection prefs: $e');
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

  Future<void> _initializeDirectChatPersistence() async {
    if (!_saveDatabaseLocallyEnabled) return;
    final target = _targetHex ?? _resolveTargetHex();
    if (target == null || target.isEmpty) return;
    _targetHex = target;
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCallSign = (prefs.getString('callSign') ?? '').trim();
      final myAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );
      final normalizedTarget = _normalizeAddress(target);
      if (normalizedTarget.isEmpty) return;

      final selfId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: myAddr.isNotEmpty ? myAddr : '__SELF__',
          displayName: myCallSign.isNotEmpty ? myCallSign : 'You',
        ),
      );
      final targetId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: normalizedTarget,
          displayName: widget.title.trim().isNotEmpty
              ? widget.title.trim()
              : '0x$normalizedTarget',
        ),
      );

      _selfContactId = selfId;
      _targetContactId = targetId;

      await _loadDirectMessagesFromDb();
    } catch (e) {
      debugPrint('Failed to initialize direct chat persistence: $e');
    }
  }

  Future<void> _loadDirectMessagesFromDb() async {
    final selfId = _selfContactId;
    final targetId = _targetContactId;
    if (selfId == null || targetId == null) return;
    try {
      final records = await LocalDatabaseService.instance.listDirectMessages(
        contactA: selfId,
        contactB: targetId,
      );
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(
            records.map((record) {
              final isOutgoing = record.fromContactId == selfId;
              return ChatMessage(
                text: record.payload,
                sender: isOutgoing ? 'You' : widget.title,
                timestamp: _parseMessageTime(record),
                isSystem: false,
                deliveryStatus: _toUiDeliveryStatus(record.deliveryStatus),
              );
            }),
          );
        if (_messages.isEmpty) {
          _messages.add(
            ChatMessage(
              text: 'Connect to a LoRa node (saved IP/port), then send via /send. ',
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
    required int fromContactId,
    required int toContactId,
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
        fromContactId: fromContactId,
        toContactId: toContactId,
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
    final fromTitle =
        RegExp(r'0x([0-9A-Fa-f]{2,4})', caseSensitive: false)
            .firstMatch(widget.title);
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
    // Drop trailing non-ASCII homoglyph noise (e.g. repeated Greek letters).
    text = text.replaceFirst(RegExp(r'[^\x20-\x7E]+$'), '').trimRight();
    return text;
  }

  String _sanitizeIncomingTextRelay(String raw) {
    var text = raw.trim();
    // Handle nested wrapper payloads:
    // - MSG|SRC|DEST|message
    // - RELAY|DEST|MSG|SRC|DEST|message
    final nestedMsg = RegExp(
      r'^(?:RELAY\|[0-9A-Fa-f]{2,4}\|)?MSG\|[0-9A-Fa-f]{2,4}\|[0-9A-Fa-f]{2,4}\|(.+)$',
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
        decodedRaw =
            jsonDecode(sanitizeJsonControlCharsInStrings(rawBody));
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

  Future<void> _appendIncomingDirectMessage({
    required String text,
    required String sender,
  }) async {
    if (!mounted) return;
    final selfId = _selfContactId;
    final targetId = _targetContactId;
    if (selfId != null && targetId != null) {
      await _persistDirectMessage(
        messageUuid: _newMessageUuid(),
        fromContactId: targetId,
        toContactId: selfId,
        payload: text,
        status: MessageDeliveryStatus.none,
        isIncoming: true,
      );
    }
    if (!mounted) return;
    setState(() {
      _messages.add(
        ChatMessage(
          text: text,
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
      final decoded = _tryDecodeStatusJson(rawBody);
      if (decoded == null) return;

      final traffic = _trafficFromStatus(decoded);

      final lastRx = traffic['lastReceived']?.toString().trim() ?? '';
      if (lastRx.isEmpty || lastRx == _lastRxText) return;

      if (_isIgnoredStatusNoise(lastRx)) {
        _lastRxText = lastRx;
        return;
      }

      _lastRxText = lastRx;

      final tagged = _reFromTagged.firstMatch(lastRx);
      if (tagged != null) {
        var fromHex = (tagged.group(1) ?? '').toUpperCase();
        final text = _sanitizeIncomingText(tagged.group(2) ?? '');
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
        final destHex = (relay.group(1) ?? '').toUpperCase();
        final text = _sanitizeIncomingTextRelay(relay.group(5) ?? '');
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null &&
            destHex.toUpperCase() != target.toUpperCase()) {
          return;
        }

        await _appendIncomingDirectMessage(
          text: text,
          sender: 'Via relay -> 0x$destHex',
        );
        return;
      }

      // MSG|SRC|DEST|payload
      final msgRelay = _reMsgPipe.firstMatch(lastRx);
      if (msgRelay != null) {
        final srcNorm =
            _normalizeNodeHex((msgRelay.group(1) ?? '').toUpperCase());
        final destNorm =
            _normalizeNodeHex((msgRelay.group(2) ?? '').toUpperCase());
        final text = _sanitizeIncomingTextRelay(msgRelay.group(3) ?? '');
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null &&
            destNorm.toUpperCase() != target.toUpperCase()) {
          return;
        }

        await _appendIncomingDirectMessage(
          text: text,
          sender: 'Via relay $srcNorm -> 0x$destNorm',
        );
        return;
      }

      // Plain LoRa payload (firmware stores raw `rc.data` in lastReceived).
      final plainText = _sanitizeIncomingText(lastRx);
      if (plainText.isEmpty) return;
      final splitParts = plainText
          .split('|')
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .toList();
      final displayText =
          splitParts.isNotEmpty ? splitParts.last : plainText;

      final peerLabel = widget.title.trim().isNotEmpty
          ? widget.title.trim()
          : 'Peer';
      await _appendIncomingDirectMessage(
        text: displayText,
        sender: peerLabel,
      );
    } catch (e) {
      debugPrint('Failed to fetch messages: $e');
    }
  }

  Future<void> _sendMessage() async {
    final messageText = _messageController.text.trim();
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
      _currentMessageLength = 0;
    });
    final selfId = _selfContactId;
    final targetId = _targetContactId;
    if (selfId != null && targetId != null) {
      final uuid = _newMessageUuid();
      _messageUuidByIndex[outgoingIndex] = uuid;
      try {
        await _persistDirectMessage(
          messageUuid: uuid,
          fromContactId: selfId,
          toContactId: targetId,
          payload: messageText,
          status: MessageDeliveryStatus.sending,
        );
      } catch (e) {
        debugPrint('Failed to persist outgoing direct message: $e');
      }
    }
    _messageController.clear();
    _scrollToBottom();

    try {
      final target = _targetHex;
      // Firmware handleSend: /send?msg=... optional &to=AABB.
      final query = <String, String>{'msg': messageText};
      if (target != null && target.isNotEmpty) {
        query['to'] = target;
      }

      final uri = _buildUri('/send', query);
      final response = await http.get(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Connection timeout'),
      );
      final body = _decodeResponseBody(response).trim();

      if (response.statusCode == 200) {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.acked);
      } else if (response.statusCode == 504 ||
          body.toUpperCase().contains('NO ACK') ||
          body.toUpperCase().contains('TIMEOUT')) {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.noAck);
      } else {
        _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.failed);
        throw Exception('Server returned: ${response.statusCode} - $body');
      }
    } catch (e) {
      _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.failed);
      if (!mounted) return;
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(
      //     content: Text('Failed to send message: ${e.toString()}'),
      //     backgroundColor: Colors.red,
      //   ),
      // );
    }
  }

  void _updateOutgoingDeliveryStatus(int index, MessageDeliveryStatus status) {
    if (!mounted || index < 0 || index >= _messages.length) return;
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

    final messageText = message.text.trim();
    if (messageText.isEmpty) return;

    _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.sending);

    try {
      final target = _targetHex;
      final query = <String, String>{'msg': messageText};
      if (target != null && target.isNotEmpty) {
        query['to'] = target;
      }

      final uri = _buildUri('/send', query);
      final response = await http.get(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Connection timeout'),
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
    } catch (_) {
      _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.failed);
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
          contactA: selfId,
          contactB: targetId,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete history: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final targetLabel =
        _targetHex == null ? 'Device default' : '0x$_targetHex';
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
            Text(targetLabel,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
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
                      if (!_canResendMessage(message)) {
                        return bubble;
                      }
                      return GestureDetector(
                        onLongPress: () {
                          showDialog<void>(
                            context: context,
                            builder: (_) => IosStyleContextMenu(
                              child: bubble,
                              actions: [
                                ContextMenuAndroid(
                                  icon: Icons.refresh,
                                  label: AppLocalizations.of(context).tr('resend'),
                                  onTap: () => unawaited(_resendMessageAt(index)),
                                ),
                              ],
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        // Message input

                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceVariant
                                  .withOpacity(0.9),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: TextField(
                              controller: _messageController,
                              decoration: const InputDecoration(
                                hintText: 'Type a message…',
                                border: InputBorder.none,
                                counterText: '',
                              ),
                              maxLines: 4,
                              minLines: 1,
                              maxLength: 50,
                              textCapitalization:
                                  TextCapitalization.sentences,
                              onChanged: (value) {
                                setState(() {
                                  _currentMessageLength =
                                      value.length.clamp(0, 50);
                                });
                              },
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Send button
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
                        '${_currentMessageLength} / 50',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
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

