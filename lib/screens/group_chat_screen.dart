import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:context_menu_android/features/context_menu/data/models/context_menu.dart';
import 'package:context_menu_android/features/context_menu/presentation/widget/ios_style_context_menu.dart';
import 'dart:convert';
import 'dart:async';
import '../models/chat_message.dart';
import 'group_details_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_database_service.dart';
import '../services/chat_unread_dot_service.dart';
import '../services/message_background_service.dart';
import '../utils/gps_message_utils.dart';
import '../utils/group_wire_utils.dart';
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
  static const String _groupsChangedAtPrefKey = 'groups_changed_at_ms';
  static const Duration _messagePollInterval = Duration(milliseconds: 800);
  static const Duration _statusPollTimeout = Duration(seconds: 2);
  static const Duration _sendTimeout = Duration(seconds: 12);
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  bool _saveDatabaseLocallyEnabled = false;
  String _powerMode = 'powerModeBalanced';

  int get _maxMessageLength => _powerMode == 'powerModeBalanced' ? 100 : 50;
  int get _maxGroupPayloadLength {
    final senderName = _selfCallSign.isNotEmpty ? _selfCallSign : 'Unknown';
    final senderAddr = _selfAddr.isNotEmpty ? _selfAddr : '0000';
    final groupWireId = GroupWireUtils.wireToken(widget.groupUuid);
    final overhead = 'GROUP_MSG|$groupWireId|$senderName&$senderAddr: '.length;
    return (_maxMessageLength - overhead).clamp(1, _maxMessageLength);
  }

  final List<ChatMessage> _messages = [];
  List<GroupMemberContactRecord> _groupMembers =
      const <GroupMemberContactRecord>[];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  Timer? _dbMessageSyncTimer;
  List<String> _targetHexes = const <String>[];
  String _selfCallSign = '';
  String _selfAddr = '';
  int? _selfContactId;
  String _lastRxText = '';
  int? _lastRxReceivedCount;
  int? _lastDbSyncedReceivedCount;
  int _currentMessageLength = 0;
  final Map<int, String> _messageUuidByIndex = <int, String>{};
  final Map<int, Map<String, MessageDeliveryStatus>>
  _targetDeliveryStatusByIndex = <int, Map<String, MessageDeliveryStatus>>{};

  /// Avoid overlapping `/api/status` polls (timer can fire while a request is still in flight).
  bool _fetchMessagesInFlight = false;
  bool _dbMessageSyncInFlight = false;

  /// LoRa firmware often cannot serve `/api/status` while handling `/send`; pause polling during outbound delivery.
  bool _suspendGroupStatusPoll = false;
  DateTime? _lastSoftAckAt;
  final Map<int, DateTime> _outgoingCreatedAtByIndex = <int, DateTime>{};
  static const Duration _softAckMatchWindow = Duration(minutes: 2);
  Timer? _groupsSyncTimer;
  int _lastObservedGroupsChangedAt = 0;
  int _lastObservedMessagesChangedAt = 0;

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
      _messagePollInterval,
      (_) => _fetchMessages(),
    );
    _dbMessageSyncTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_refreshPersistedMessagesIfChanged()),
    );
    _groupsSyncTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshGroupRosterIfChanged()),
    );
    _loadGroupMessagesFromDb();
    _fetchMessages();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ChatUnreadDotService.clearGroupUnread(widget.groupUuid));
    });
  }

  @override
  void didUpdateWidget(GroupChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _lastRxText = '';
      _lastRxReceivedCount = null;
      _messageUuidByIndex.clear();
      _outgoingCreatedAtByIndex.clear();
      _targetDeliveryStatusByIndex.clear();
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
    _dbMessageSyncTimer?.cancel();
    _groupsSyncTimer?.cancel();
    super.dispose();
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
      if (_saveDatabaseLocallyEnabled) {
        await _loadGroupMessagesFromDb();
      } else {
        await _fetchMessages();
      }
      await ChatUnreadDotService.clearGroupUnread(widget.groupUuid);
    } catch (e) {
      debugPrint('Failed to refresh persisted group messages: $e');
    } finally {
      _dbMessageSyncInFlight = false;
    }
  }

  Future<void> _refreshGroupRosterIfChanged() async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final changedAt = prefs.getInt(_groupsChangedAtPrefKey) ?? 0;
      if (changedAt > _lastObservedGroupsChangedAt) {
        _lastObservedGroupsChangedAt = changedAt;
        await _loadGroupMembers();
      }
    } catch (_) {
      // Best effort.
    }
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
      final myCallSign = (prefs.getString('callSign') ?? '')
          .trim()
          .toUpperCase();
      final myAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );

      if (!mounted) return;

      setState(() {
        deviceIp = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        devicePort = (savedPort != null && savedPort.isNotEmpty)
            ? savedPort
            : '';
        _isConnected = deviceIp.isNotEmpty;
        _saveDatabaseLocallyEnabled = saveDbEnabled;
        _selfCallSign = myCallSign;
        _selfAddr = myAddr;
        if (storedPowerMode != null && storedPowerMode.isNotEmpty) {
          _powerMode = storedPowerMode;
        }
        _currentMessageLength = _currentMessageLength.clamp(
          0,
          _maxGroupPayloadLength,
        );
      });
      await _ensureSelfContact();
      // Re-resolve targets now that self address / callsign are known.
      await _loadGroupMembers();
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

  MessageDeliveryStatus _toLoadedUiDeliveryStatus(
    MessageRecord record, {
    required bool isOutgoing,
  }) {
    return _toUiDeliveryStatus(record.deliveryStatus);
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
    if (_selfContactId != null && contactId == _selfContactId.toString()) {
      return 'You';
    }
    for (final member in _groupMembers) {
      if (member.contactId.toString() == contactId) {
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
      final targetStatusesByUuid =
          <String, Map<String, MessageDeliveryStatus>>{};
      for (final entry in _messageUuidByIndex.entries) {
        final uuid = entry.value;
        final statuses = _targetDeliveryStatusByIndex[entry.key];
        if (statuses == null || statuses.isEmpty) continue;
        targetStatusesByUuid[uuid] = Map<String, MessageDeliveryStatus>.from(
          statuses,
        );
      }
      setState(() {
        _messageUuidByIndex.clear();
        _outgoingCreatedAtByIndex.clear();
        _targetDeliveryStatusByIndex.clear();
        _messages
          ..clear()
          ..addAll(
            records.asMap().entries.map((entry) {
              final i = entry.key;
              final record = entry.value;
              _messageUuidByIndex[i] = record.messageUuid;
              final createdAtRaw =
                  record.createdAt ?? record.sentAt ?? record.receivedAt;
              final createdAt = DateTime.tryParse(
                createdAtRaw ?? '',
              )?.toLocal();
              if (createdAt != null) {
                _outgoingCreatedAtByIndex[i] = createdAt;
              }
              final isOutgoing =
                  _selfContactId != null &&
                  record.fromContactId == _selfContactId.toString();
              final restoredTargetStatuses =
                  targetStatusesByUuid[record.messageUuid];
              if (restoredTargetStatuses != null &&
                  restoredTargetStatuses.isNotEmpty) {
                _targetDeliveryStatusByIndex[i] = restoredTargetStatuses;
              }
              return ChatMessage(
                text: record.payload,
                sender: _senderLabelForContactId(
                  record.fromContactId.toString(),
                ),
                timestamp: _parseMessageTime(record),
                isSystem: false,
                deliveryStatus: _toLoadedUiDeliveryStatus(
                  record,
                  isOutgoing: isOutgoing,
                ),
                deliveryDetails: _groupTargetDeliveryDetails(i),
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

  /// Resolves a 4-hex node id for routing, even if [GroupMemberContactRecord.loraAddress]
  /// was stored as `LM-2:0002` style.
  String? _hexTargetFromMember(GroupMemberContactRecord member) {
    var h = _normalizeAddress(member.loraAddress);
    if (h.isNotEmpty) return h;
    for (final raw in [member.loraAddress, member.displayName]) {
      final s = raw.trim();
      if (s.contains(':')) {
        h = _normalizeAddress(s.split(':').last);
        if (h.isNotEmpty) return h;
      }
      if (s.contains('&')) {
        h = _normalizeAddress(s.split('&').last);
        if (h.isNotEmpty) return h;
      }
    }
    return null;
  }

  Future<int?> _findContactIdForAddress(String addressHex) async {
    final normalized = _normalizeAddress(addressHex);
    if (normalized.isEmpty) return null;
    for (final member in _groupMembers) {
      final memberAddr = _hexTargetFromMember(member);
      if (memberAddr != null && memberAddr == normalized) {
        return member.contactId;
      }
    }
    final id = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(loraAddress: normalized, displayName: '0x$normalized'),
    );
    return id;
  }

  List<String> _resolveTargetsFromMembers(
    List<GroupMemberContactRecord> members,
  ) {
    debugPrint(
      '----------------- _resolveTargetsFromMembers members ----------------------',
    );
    debugPrint('Members: ${members.map((e) => e.displayName).join(', ')}');
    debugPrint('selfAddr: $_selfAddr');
    debugPrint('targetHexes: $_targetHexes');
    final uniqueTargets = <String>{};
    for (final member in members) {
      if (_selfContactId != null && member.contactId == _selfContactId) {
        continue;
      }
      final normalizedAddress = _hexTargetFromMember(member);
      if (normalizedAddress == null || normalizedAddress.isEmpty) continue;
      if (normalizedAddress == '__SELF__') continue;
      if (_selfAddr.isNotEmpty && normalizedAddress == _selfAddr) continue;
      uniqueTargets.add(normalizedAddress);
    }
    debugPrint(
      '----------------- _resolveTargetsFromMembers uniqueTargets ----------------------',
    );
    debugPrint('UniqueTargets: ${uniqueTargets.toList()}');
    return uniqueTargets.toList()..sort();
  }

  String _targetLabel() {
    if (_targetHexes.isEmpty) {
      return AppLocalizations.of(context).tr('noMembers');
    }
    if (_targetHexes.length == 1) {
      return '2 ${AppLocalizations.of(context).tr('members')}';
    }
    return '${_targetHexes.length + 1} ${AppLocalizations.of(context).tr('members')}';
  }

  String _memberLabelForTarget(String targetHex) {
    final normalized = _normalizeAddress(targetHex);
    for (final member in _groupMembers) {
      final memberAddr = _hexTargetFromMember(member);
      if (memberAddr != null && memberAddr == normalized) {
        final name = member.displayName.trim();
        if (name.isNotEmpty) return name;
      }
    }
    return normalized.isEmpty ? 'Unknown' : '0x$normalized';
  }

  String _groupTargetDeliveryDetails(int index) {
    final statuses = _targetDeliveryStatusByIndex[index];
    if (statuses == null || statuses.isEmpty) return '';

    String namesFor(MessageDeliveryStatus status) {
      return statuses.entries
          .where((entry) => entry.value == status)
          .map((entry) => _memberLabelForTarget(entry.key))
          .join(', ');
    }

    final lines = <String>[];
    final acked = namesFor(MessageDeliveryStatus.acked);
    final pending = namesFor(MessageDeliveryStatus.sending);
    final noAck = namesFor(MessageDeliveryStatus.noAck);
    final failed = namesFor(MessageDeliveryStatus.failed);
    if (acked.isNotEmpty) lines.add('ACK by: $acked');
    if (pending.isNotEmpty) lines.add('Sending: $pending');
    if (noAck.isNotEmpty) lines.add('No ACK: $noAck');
    if (failed.isNotEmpty) lines.add('Failed: $failed');
    return lines.join('\n');
  }

  void _setGroupTargetDeliveryStatuses({
    required int index,
    required List<String> targets,
    required MessageDeliveryStatus status,
  }) {
    final normalizedTargets = targets
        .map(_normalizeAddress)
        .where((target) => target.isNotEmpty)
        .toList();
    if (normalizedTargets.isEmpty) return;
    if (!mounted) return;

    setState(() {
      _targetDeliveryStatusByIndex[index] = {
        for (final target in normalizedTargets) target: status,
      };
      if (index >= 0 && index < _messages.length) {
        _messages[index] = _messages[index].copyWith(
          deliveryDetails: _groupTargetDeliveryDetails(index),
        );
      }
    });
  }

  void _markGroupTargetsSending({
    required int index,
    required List<String> targets,
  }) {
    final normalizedTargets = targets
        .map(_normalizeAddress)
        .where((target) => target.isNotEmpty)
        .toList();
    if (normalizedTargets.isEmpty) return;
    if (!mounted) return;

    setState(() {
      final statuses = _targetDeliveryStatusByIndex.putIfAbsent(
        index,
        () => <String, MessageDeliveryStatus>{},
      );
      for (final target in normalizedTargets) {
        statuses[target] = MessageDeliveryStatus.sending;
      }
      if (index >= 0 && index < _messages.length) {
        _messages[index] = _messages[index].copyWith(
          deliveryDetails: _groupTargetDeliveryDetails(index),
        );
      }
    });
  }

  void _updateGroupTargetDeliveryStatus({
    required int index,
    required String target,
    required MessageDeliveryStatus status,
  }) {
    final normalizedTarget = _normalizeAddress(target);
    if (normalizedTarget.isEmpty) return;
    if (!mounted) return;

    setState(() {
      final statuses = _targetDeliveryStatusByIndex.putIfAbsent(
        index,
        () => <String, MessageDeliveryStatus>{},
      );
      statuses[normalizedTarget] = status;
      if (index >= 0 && index < _messages.length) {
        _messages[index] = _messages[index].copyWith(
          deliveryDetails: _groupTargetDeliveryDetails(index),
        );
      }
    });
  }

  void _setGroupTargetDeliveryStatusMap({
    required int index,
    required Map<String, MessageDeliveryStatus> statuses,
  }) {
    if (statuses.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _targetDeliveryStatusByIndex[index] =
          Map<String, MessageDeliveryStatus>.from(statuses);
      if (index >= 0 && index < _messages.length) {
        _messages[index] = _messages[index].copyWith(
          deliveryDetails: _groupTargetDeliveryDetails(index),
        );
      }
    });
  }

  MessageDeliveryStatus _overallGroupDeliveryStatusForTargets({
    required int index,
    required List<String> expectedTargets,
  }) {
    final normalizedTargets = expectedTargets
        .map(_normalizeAddress)
        .where((target) => target.isNotEmpty)
        .toList();
    if (normalizedTargets.isEmpty) return MessageDeliveryStatus.failed;

    final statuses = _targetDeliveryStatusByIndex[index] ?? const {};
    var ackedCount = 0;
    var failedCount = 0;
    var sendingCount = 0;

    for (final target in normalizedTargets) {
      final status = statuses[target] ?? MessageDeliveryStatus.noAck;
      switch (status) {
        case MessageDeliveryStatus.acked:
          ackedCount += 1;
        case MessageDeliveryStatus.failed:
          failedCount += 1;
        case MessageDeliveryStatus.sending:
          sendingCount += 1;
        case MessageDeliveryStatus.noAck:
        case MessageDeliveryStatus.none:
          break;
      }
    }

    if (ackedCount == normalizedTargets.length) {
      return MessageDeliveryStatus.acked;
    }
    if (sendingCount > 0) return MessageDeliveryStatus.sending;
    if (failedCount == normalizedTargets.length) {
      return MessageDeliveryStatus.failed;
    }
    return MessageDeliveryStatus.noAck;
  }

  List<String> _failedGroupTargetsForRetry({
    required int index,
    required List<String> fallbackTargets,
  }) {
    final statuses = _targetDeliveryStatusByIndex[index];
    if (statuses == null || statuses.isEmpty) return fallbackTargets;

    final retryTargets = <String>[];
    final fallbackSet = fallbackTargets.map(_normalizeAddress).toSet();
    for (final entry in statuses.entries) {
      final target = _normalizeAddress(entry.key);
      if (target.isEmpty || !fallbackSet.contains(target)) continue;
      if (entry.value == MessageDeliveryStatus.failed ||
          entry.value == MessageDeliveryStatus.noAck) {
        retryTargets.add(target);
      }
    }
    retryTargets.sort();
    return retryTargets;
  }

  void _updateOutgoingMessageText(int index, String text) {
    final nextText = text.trim();
    if (nextText.isEmpty) return;
    if (!mounted || index < 0 || index >= _messages.length) return;
    setState(() {
      _messages[index] = _messages[index].copyWith(text: nextText);
    });
    final uuid = _messageUuidByIndex[index];
    if (uuid == null) return;
    unawaited(
      LocalDatabaseService.instance.updateMessagePayload(
        messageUuid: uuid,
        payload: nextText,
      ),
    );
  }

  Future<({GroupDetailsRecord details, List<String> sendTargets})?>
  _prepareGroupSendContext() async {
    if (!_isConnected || deviceIp.trim().isEmpty) {
      await _loadConnectionPrefs();
    }
    await _ensureSelfContact();
    await _syncGroupMembersBeforeSend();

    if (!_isConnected || deviceIp.trim().isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to a mesh network first'),
          backgroundColor: Colors.orange,
        ),
      );
      return null;
    }

    final details = await LocalDatabaseService.instance.getGroupDetails(
      widget.groupId,
    );
    if (!mounted) return null;

    if (details == null ||
        details.groupUuid.trim() != widget.groupUuid.trim()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load this group. Try opening it again.'),
          backgroundColor: Colors.orange,
        ),
      );
      return null;
    }

    var sendMembers = details.members;
    var sendTargets = _resolveTargetsFromMembers(sendMembers);
    if (sendTargets.isEmpty) {
      await _loadGroupMembers();
      sendMembers = _groupMembers;
      sendTargets = _resolveTargetsFromMembers(sendMembers);
    }

    if (sendTargets.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No valid group members found'),
          backgroundColor: Colors.orange,
        ),
      );
      return null;
    }

    setState(() {
      _groupMembers = sendMembers;
      _targetHexes = sendTargets;
    });
    return (details: details, sendTargets: sendTargets);
  }

  Future<void> _syncGroupMembersBeforeSend() async {
    await _loadGroupMembers();
    final details = await LocalDatabaseService.instance.getGroupDetails(
      widget.groupId,
    );
    if (details == null) return;

    for (final member in details.members) {
      final addr = _hexTargetFromMember(member);
      if (addr == null || addr.isEmpty) continue;
      final contactId = await LocalDatabaseService.instance.upsertContact(
        ContactRecord(
          loraAddress: addr,
          displayName: member.displayName.trim().isNotEmpty
              ? member.displayName.trim()
              : '0x$addr',
        ),
      );
      await LocalDatabaseService.instance.upsertGroupMember(
        GroupMemberRecord(
          groupUuid: widget.groupUuid,
          contactId: contactId,
          role: member.role,
          isActive: true,
        ),
      );
    }
    await _loadGroupMembers();
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

  String _senderLabelForAddress(String addressHex) {
    final normalized = _normalizeAddress(addressHex);
    if (normalized.isEmpty) return 'Unknown node';
    for (final member in _groupMembers) {
      final memberAddr = _hexTargetFromMember(member);
      if (memberAddr != null && memberAddr == normalized) {
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
    return GpsMessageUtils.formatResponseMessage(text);
  }

  void _softAckOutgoingIfMatched(String incomingText) {
    final text = incomingText.trim();
    if (text.isEmpty) return;

    // Avoid flapping if firmware repeats lastReceived quickly.
    final now = DateTime.now();
    final last = _lastSoftAckAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 600)) {
      return;
    }

    // Find the most recent outgoing message from "You" that matches this payload
    // and is currently "No Ack"/"Sending"/"Failed". Upgrade it to ACKed.
    for (var i = _messages.length - 1; i >= 0; i -= 1) {
      final m = _messages[i];
      if (m.isSystem) continue;
      if (m.sender != 'You') continue;
      if (m.text.trim() != text) continue;
      final outgoingTime = _outgoingCreatedAtByIndex[i] ?? m.timestamp;
      if (now.difference(outgoingTime).abs() > _softAckMatchWindow) {
        continue;
      }

      final current = m.deliveryStatus;
      if (current == MessageDeliveryStatus.acked) return;
      if (current != MessageDeliveryStatus.noAck &&
          current != MessageDeliveryStatus.sending &&
          current != MessageDeliveryStatus.failed) {
        continue;
      }

      _lastSoftAckAt = now;
      _updateOutgoingDeliveryStatus(i, MessageDeliveryStatus.acked);
      return;
    }
  }

  ({String senderAddr, String text})? _tryExtractSenderAddrPayload(
    String payload,
  ) {
    final match = RegExp(
      r'^([^&:|]+)&([0-9A-Fa-f]{2,8})\s*:\s*(.+)$',
    ).firstMatch(payload.trim());
    if (match == null) return null;
    final senderAddr = _normalizeAddress(match.group(2) ?? '');
    final text = _sanitizeIncomingText(match.group(3) ?? '');
    if (senderAddr.isEmpty || text.isEmpty) return null;
    return (senderAddr: senderAddr, text: text);
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

  ({String? groupToken, String payload}) _extractGroupWirePayload(
    String payload,
  ) {
    final trimmed = payload.trim();
    final match = RegExp(r'^GROUP_MSG\|([^|]+)\|(.+)$').firstMatch(trimmed);
    if (match == null) return (groupToken: null, payload: payload);
    final token = (match.group(1) ?? '').trim();
    final wrappedPayload = (match.group(2) ?? '').trim();
    if (token.isEmpty || wrappedPayload.isEmpty) {
      return (groupToken: null, payload: payload);
    }
    return (groupToken: token, payload: wrappedPayload);
  }

  /// True if [lastRx] carries a GROUP_MSG frame for this group's wire token (UUID).
  bool _lastRxContainsGroupMsgForThisChat(String lastRx) {
    final groupUuid = widget.groupUuid.trim();
    if (groupUuid.isEmpty) return false;
    final fullNeedle = 'GROUP_MSG|$groupUuid|'.toUpperCase();
    final compactNeedle = 'GROUP_MSG|${GroupWireUtils.wireToken(groupUuid)}|'
        .toUpperCase();
    final upper = lastRx.toUpperCase();
    return upper.contains(fullNeedle) || upper.contains(compactNeedle);
  }

  bool _isGroupTokenForThisChat(String? token) {
    if (token == null || token.trim().isEmpty) return false;
    return GroupWireUtils.tokenMatchesGroup(token, widget.groupUuid);
  }

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
    if (_suspendGroupStatusPoll) return;
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
      if (_saveDatabaseLocallyEnabled &&
          currentReceivedCount != null &&
          currentReceivedCount != _lastDbSyncedReceivedCount) {
        _lastDbSyncedReceivedCount = currentReceivedCount;
        // Keep current chat in sync even if live parser misses a wire variant.
        await _loadGroupMessagesFromDb();
      }
      final isDuplicate =
          lastRx == _lastRxText &&
          currentReceivedCount != null &&
          _lastRxReceivedCount != null &&
          currentReceivedCount == _lastRxReceivedCount;
      if (isDuplicate) {
        // Background notifier may update prefs before this screen ingests the frame.
        // Reload from DB so the same "recent message" shown in notification appears here.
        if (_saveDatabaseLocallyEnabled &&
            _lastRxContainsGroupMsgForThisChat(lastRx)) {
          await _loadGroupMessagesFromDb();
        }
        return;
      }

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

      // Ignore group control frames; background service updates the local DB.
      if (lastRx.contains('GROUP_INVITE|')) {
        return;
      }
      if (lastRx.contains('GROUP_MEMBER_REMOVE|')) {
        return;
      }

      final tagged = RegExp(
        r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(lastRx);
      if (tagged != null) {
        final fromHex = _normalizeAddress(tagged.group(1) ?? '');
        final extracted = _extractGroupWirePayload(tagged.group(2) ?? '');
        if (extracted.groupToken != null &&
            !_isGroupTokenForThisChat(extracted.groupToken)) {
          return;
        }
        final senderAddrPayload = _tryExtractSenderAddrPayload(
          extracted.payload,
        );
        if (_selfAddr.isNotEmpty &&
            senderAddrPayload != null &&
            senderAddrPayload.senderAddr == _selfAddr) {
          _softAckOutgoingIfMatched(senderAddrPayload.text);
          return;
        }
        final parsed = _splitSenderFromPayload(extracted.payload);
        if (parsed.text.isEmpty) return;
        if (fromHex == _selfAddr) {
          // If we see our own group payload come back in lastReceived, treat it as
          // a delivery confirmation and upgrade the latest matching outgoing message.
          _softAckOutgoingIfMatched(parsed.text);
          return;
        }
        // Do not hard-drop by cached member list; membership can be stale while
        // user is already in chat. If group token matches, render the message.

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
        final relayDest = _normalizeAddress(destHex);
        final extracted = _extractGroupWirePayload(relay.group(2) ?? '');
        if (extracted.groupToken != null &&
            !_isGroupTokenForThisChat(extracted.groupToken)) {
          return;
        }
        final senderAddrPayload = _tryExtractSenderAddrPayload(
          extracted.payload,
        );
        if (_selfAddr.isNotEmpty &&
            senderAddrPayload != null &&
            senderAddrPayload.senderAddr == _selfAddr) {
          _softAckOutgoingIfMatched(senderAddrPayload.text);
          return;
        }
        final parsed = _splitSenderFromPayload(extracted.payload);
        if (parsed.text.isEmpty) return;
        // Do not hard-drop relayed frames using cached target list. While user is
        // active in chat, members/targets may lag behind and hide valid messages.
        if (!mounted) return;
        int? fromContactId = relayDest.isNotEmpty
            ? await _findContactIdForAddress(relayDest)
            : null;
        fromContactId ??= await LocalDatabaseService.instance.upsertContact(
          ContactRecord(
            loraAddress: '__GROUP_RELAY__$relayDest',
            displayName: parsed.senderName ?? 'Relay',
          ),
        );
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
      if (extracted.groupToken != null &&
          !_isGroupTokenForThisChat(extracted.groupToken)) {
        return;
      }
      final senderAddrPayload = _tryExtractSenderAddrPayload(extracted.payload);
      if (_selfAddr.isNotEmpty &&
          senderAddrPayload != null &&
          senderAddrPayload.senderAddr == _selfAddr) {
        _softAckOutgoingIfMatched(senderAddrPayload.text);
        return;
      }
      final plain = _splitSenderFromPayload(extracted.payload);
      final sender = plain.senderName?.trim() ?? '';
      if (plain.text.isEmpty || sender.isEmpty) return;
      if (_selfCallSign.isNotEmpty &&
          sender.toUpperCase() == _selfCallSign.toUpperCase()) {
        _softAckOutgoingIfMatched(plain.text);
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
    } on TimeoutException catch (_) {
      // Busy radio / device handling send — avoid noisy "failed fetch" spam.
      debugPrint('Group chat: /api/status timed out (will retry on next poll)');
    } catch (e) {
      debugPrint('Failed to fetch group messages: $e');
    } finally {
      _fetchMessagesInFlight = false;
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

  MessageDeliveryStatus _groupDeliveryStatus({
    required int total,
    required int ackedCount,
    required int definitiveFailCount,
  }) {
    if (total <= 0) return MessageDeliveryStatus.failed;
    if (ackedCount == total) return MessageDeliveryStatus.acked;
    if (ackedCount == 0 && definitiveFailCount == total) {
      return MessageDeliveryStatus.failed;
    }
    return MessageDeliveryStatus.noAck;
  }

  Future<int> _appendOutgoingGroupMessage(
    String messageText, {
    MessageDeliveryStatus status = MessageDeliveryStatus.sending,
    String persistErrorLabel = 'outgoing group message',
  }) async {
    var outgoingIndex = -1;
    setState(() {
      outgoingIndex = _messages.length;
      final now = DateTime.now();
      _outgoingCreatedAtByIndex[outgoingIndex] = now;
      _messages.add(
        ChatMessage(
          text: messageText,
          sender: 'You',
          timestamp: now,
          isSystem: false,
          deliveryStatus: status,
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
          status: status,
        );
      } catch (e) {
        debugPrint('Failed to persist $persistErrorLabel: $e');
      }
    }

    _scrollToBottom();
    return outgoingIndex;
  }

  Map<String, String> _buildGpsQueryForTarget(
    String target, {
    bool useRelay = false,
  }) {
    final query = <String, String>{'to': target};
    if (useRelay) {
      query['relay'] = '1';
    }
    return query;
  }

  Future<
    ({
      int ackedCount,
      int definitiveFailCount,
      String? firstResponseBody,
      Map<String, MessageDeliveryStatus> targetStatuses,
    })
  >
  _sendRequestToGroupTargets({
    required List<String> sendTargets,
    required String path,
    required Map<String, String> Function(String target) queryForTarget,
    required String timeoutLabel,
    required MessageDeliveryStatus Function(http.Response response, String body)
    deliveryStatusForResponse,
    bool Function(http.Response response)? isDefinitiveFailure,
    void Function(String target, MessageDeliveryStatus status)?
    onTargetComplete,
  }) async {
    var ackedCount = 0;
    var definitiveFailCount = 0;
    String? firstResponseBody;
    final targetStatuses = <String, MessageDeliveryStatus>{};

    void completeTarget(String target, MessageDeliveryStatus status) {
      final normalizedTarget = _normalizeAddress(target);
      if (normalizedTarget.isNotEmpty) {
        targetStatuses[normalizedTarget] = status;
      }
      onTargetComplete?.call(target, status);
    }

    for (final target in sendTargets) {
      try {
        final uri = _buildUri(path, queryForTarget(target));
        final response = await http
            .get(uri)
            .timeout(
              _sendTimeout,
              onTimeout: () => throw TimeoutException(timeoutLabel),
            );
        final body = _decodeResponseBody(response).trim();
        if (firstResponseBody == null && body.isNotEmpty) {
          firstResponseBody = body;
        }

        final deliveryStatus = deliveryStatusForResponse(response, body);
        if (deliveryStatus == MessageDeliveryStatus.acked) {
          ackedCount += 1;
          completeTarget(target, MessageDeliveryStatus.acked);
        } else if (deliveryStatus == MessageDeliveryStatus.failed &&
            (isDefinitiveFailure?.call(response) ?? true)) {
          definitiveFailCount += 1;
          completeTarget(target, MessageDeliveryStatus.failed);
        } else {
          completeTarget(target, MessageDeliveryStatus.noAck);
        }
      } on TimeoutException catch (_) {
        // Timeouts are no-ack style uncertainty; leave the message retryable.
        completeTarget(target, MessageDeliveryStatus.noAck);
      } catch (_) {
        // Transport failures mean this request definitively did not leave via HTTP.
        definitiveFailCount += 1;
        completeTarget(target, MessageDeliveryStatus.failed);
      }
    }

    return (
      ackedCount: ackedCount,
      definitiveFailCount: definitiveFailCount,
      firstResponseBody: firstResponseBody,
      targetStatuses: targetStatuses,
    );
  }

  Future<void> _deliverGroupMessageToTargets({
    required String plainText,
    required int outgoingIndex,
    required List<String> sendTargets,
    bool resetTargetStatuses = true,

    /// Numeric DB group id — must match firmware / local parser (`GROUP_MSG|<id>|...`).
    required String groupWireId,
  }) async {
    final senderName = _selfCallSign.isNotEmpty ? _selfCallSign : 'Unknown';
    final senderAddr = _selfAddr.isNotEmpty ? _selfAddr : '0000';
    final payloadWithName =
        'GROUP_MSG|$groupWireId|$senderName&$senderAddr: $plainText';
    if (resetTargetStatuses) {
      _setGroupTargetDeliveryStatuses(
        index: outgoingIndex,
        targets: sendTargets,
        status: MessageDeliveryStatus.sending,
      );
    } else {
      _markGroupTargetsSending(index: outgoingIndex, targets: sendTargets);
    }
    _suspendGroupStatusPoll = true;
    try {
      await _sendRequestToGroupTargets(
        sendTargets: sendTargets,
        path: '/send',
        timeoutLabel: '/send',
        queryForTarget: (target) => <String, String>{
          'msg': payloadWithName,
          'to': target,
        },
        deliveryStatusForResponse: (response, body) {
          final normalizedBody = body.toUpperCase();
          if (response.statusCode == 200) return MessageDeliveryStatus.acked;
          if (response.statusCode == 504 ||
              normalizedBody.contains('NO ACK') ||
              normalizedBody.contains('TIMEOUT')) {
            return MessageDeliveryStatus.noAck;
          }
          return MessageDeliveryStatus.failed;
        },
        isDefinitiveFailure: (response) =>
            response.statusCode >= 400 &&
            response.statusCode < 500 &&
            response.statusCode != 408 &&
            response.statusCode != 429,
        onTargetComplete: (target, status) => _updateGroupTargetDeliveryStatus(
          index: outgoingIndex,
          target: target,
          status: status,
        ),
      );

      final status = _overallGroupDeliveryStatusForTargets(
        index: outgoingIndex,
        expectedTargets:
            _targetDeliveryStatusByIndex[outgoingIndex]?.keys.toList() ??
            sendTargets,
      );
      _updateOutgoingDeliveryStatus(outgoingIndex, status);
    } catch (_) {
      // Unexpected wrapper-level failure: keep retry-friendly no-ack state.
      _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.noAck);
      if (!mounted) return;
      setState(() {
        _currentMessageLength = 0;
      });
    } finally {
      _suspendGroupStatusPoll = false;
      _schedulePostSendPolls();
      if (_saveDatabaseLocallyEnabled && mounted) {
        // Merge any row persisted by background service (same frame as notification).
        await _loadGroupMessagesFromDb();
      }
    }
  }

  Future<void> _sendGPS({bool useRelay = false}) async {
    final sendContext = await _prepareGroupSendContext();
    if (sendContext == null) return;
    final sendTargets = sendContext.sendTargets;
    final outgoingIndex = await _appendOutgoingGroupMessage(
      GpsMessageUtils.fallbackMessage,
      persistErrorLabel: 'outgoing group GPS message',
    );
    _setGroupTargetDeliveryStatuses(
      index: outgoingIndex,
      targets: sendTargets,
      status: MessageDeliveryStatus.sending,
    );

    _suspendGroupStatusPoll = true;
    try {
      final delivery = await _sendRequestToGroupTargets(
        sendTargets: sendTargets,
        path: '/gps',
        timeoutLabel: '/gps',
        queryForTarget: (target) =>
            _buildGpsQueryForTarget(target, useRelay: useRelay),
        deliveryStatusForResponse: GpsMessageUtils.deliveryStatusFromResponse,
        isDefinitiveFailure: GpsMessageUtils.isDefinitiveHttpFailure,
        onTargetComplete: (target, status) => _updateGroupTargetDeliveryStatus(
          index: outgoingIndex,
          target: target,
          status: status,
        ),
      );

      final status = _groupDeliveryStatus(
        total: sendTargets.length,
        ackedCount: delivery.ackedCount,
        definitiveFailCount: delivery.definitiveFailCount,
      );
      final messageText = GpsMessageUtils.formatResponseMessage(
        delivery.firstResponseBody ?? '',
      ).trim();
      _updateOutgoingMessageText(
        outgoingIndex,
        messageText.isEmpty ? GpsMessageUtils.fallbackMessage : messageText,
      );
      _setGroupTargetDeliveryStatusMap(
        index: outgoingIndex,
        statuses: delivery.targetStatuses,
      );
      _updateOutgoingDeliveryStatus(outgoingIndex, status);

      if (!mounted) return;
      if (status == MessageDeliveryStatus.failed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send GPS to group'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      _suspendGroupStatusPoll = false;
      _schedulePostSendPolls();
      if (_saveDatabaseLocallyEnabled && mounted) {
        await _loadGroupMessagesFromDb();
      }
    }
  }

  Future<void> _sendMessage() async {
    final messageText = _messageController.text.trim();
    if (messageText.isEmpty) return;

    final sendContext = await _prepareGroupSendContext();
    if (sendContext == null) return;

    final outgoingIndex = await _appendOutgoingGroupMessage(
      messageText,
      persistErrorLabel: 'outgoing group message',
    );
    _messageController.clear();
    setState(() {
      _currentMessageLength = 0;
    });

    await _deliverGroupMessageToTargets(
      plainText: messageText,
      outgoingIndex: outgoingIndex,
      sendTargets: sendContext.sendTargets,
      groupWireId: GroupWireUtils.wireToken(widget.groupUuid),
    );
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

    final messageText = message.text.trim();
    if (messageText.isEmpty) return;

    final sendContext = await _prepareGroupSendContext();
    if (sendContext == null) return;

    _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.sending);
    final retryTargets = _failedGroupTargetsForRetry(
      index: index,
      fallbackTargets: sendContext.sendTargets,
    );
    if (retryTargets.isEmpty) {
      _updateOutgoingDeliveryStatus(index, MessageDeliveryStatus.acked);
      return;
    }
    await _deliverGroupMessageToTargets(
      plainText: messageText,
      outgoingIndex: index,
      sendTargets: retryTargets,
      resetTargetStatuses: false,
      groupWireId: GroupWireUtils.wireToken(widget.groupUuid),
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
        _outgoingCreatedAtByIndex.clear();
        _targetDeliveryStatusByIndex.clear();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete history: $e')));
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
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
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
                            tooltip: 'Send GPS',
                            onPressed: () => unawaited(_sendGPS()),
                            icon: const Icon(Icons.online_prediction_outlined),
                          ),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: TextField(
                                controller: _messageController,
                                decoration: const InputDecoration(
                                  hintText: 'Type a message...',
                                  border: InputBorder.none,
                                  counterText: '',
                                ),
                                maxLines: 4,
                                minLines: 1,
                                maxLength: _maxGroupPayloadLength,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                onChanged: (value) {
                                  setState(() {
                                    _currentMessageLength = value.length.clamp(
                                      0,
                                      _maxGroupPayloadLength,
                                    );
                                  });
                                },
                                onSubmitted: (_) => _sendMessage(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
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
                          '$_currentMessageLength / $_maxGroupPayloadLength',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: 11,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
