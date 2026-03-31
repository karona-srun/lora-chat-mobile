import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
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
    required this.groupTitle,
  });

  final int groupId;
  final String groupTitle;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  final List<ChatMessage> _messages = [];
  List<GroupMemberContactRecord> _groupMembers = const <GroupMemberContactRecord>[];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  List<String> _targetHexes = const <String>[];
  String _selfCallSign = '';
  String _selfAddr = '';
  String _lastRxText = '';
  int _currentMessageLength = 0;

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
    _fetchMessages();
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
    return text.replaceAll(RegExp(r'[\s:-]'), '');
  }

  Future<void> _loadConnectionPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();
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
        _selfCallSign = myCallSign;
        _selfAddr = myAddr;
      });
    } catch (e) {
      debugPrint('Failed to load connection prefs: $e');
    }
  }

  Future<void> _loadGroupMembers() async {
    try {
      final details = await LocalDatabaseService.instance.getGroupDetails(
        widget.groupId,
      );
      if (!mounted || details == null) return;
      final resolvedTargets = _resolveTargetsFromMembers(details.members);
      setState(() {
        _groupMembers = details.members;
        _targetHexes = resolvedTargets;
      });
    } catch (e) {
      debugPrint('Failed to load group members: $e');
    }
  }

  List<String> _resolveTargetsFromMembers(List<GroupMemberContactRecord> members) {
    final uniqueTargets = <String>{};
    for (final member in members) {
      final normalizedAddress = _normalizeAddress(member.loraAddress);
      final normalizedName = member.displayName.trim().toUpperCase();
      if (normalizedAddress.isEmpty) continue;
      if (normalizedAddress == '__SELF__' || normalizedName == '__SELF__') continue;
      if (_selfAddr.isNotEmpty && normalizedAddress == _selfAddr) continue;
      if (_selfCallSign.isNotEmpty && normalizedName == _selfCallSign) continue;
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
    if (addressHex.isEmpty) return false;
    final normalized = addressHex.toUpperCase();
    for (final member in _groupMembers) {
      final memberAddr = _normalizeAddress(member.loraAddress);
      if (memberAddr == normalized) return true;
    }
    return false;
  }

  String _senderLabelForAddress(String addressHex) {
    final normalized = addressHex.toUpperCase();
    for (final member in _groupMembers) {
      final memberAddr = _normalizeAddress(member.loraAddress);
      if (memberAddr == normalized) {
        final name = member.displayName.trim();
        if (name.isNotEmpty) return name;
      }
    }
    return 'Node 0x$normalized';
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
      if (lastRx.isEmpty || lastRx == _lastRxText) return;

      if (lastRx.startsWith('HELLO|')) {
        _lastRxText = lastRx;
        return;
      }
      if (RegExp(r'^\d+\|41\|', caseSensitive: false).hasMatch(lastRx)) {
        _lastRxText = lastRx;
        return;
      }

      _lastRxText = lastRx;

      final tagged = RegExp(
        r'^From 0x([0-9A-Fa-f]{2,4})\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(lastRx);
      if (tagged != null) {
        var fromHex = (tagged.group(1) ?? '').toUpperCase();
        final text = (tagged.group(2) ?? '').trim();
        if (text.isEmpty) return;
        if (fromHex.length == 2) fromHex = '00$fromHex';
        if (fromHex == _selfAddr) return;
        if (!_isGroupMemberAddress(fromHex)) return;

        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              text: text,
              sender: _senderLabelForAddress(fromHex),
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
        final text = (relay.group(2) ?? '').trim();
        if (text.isEmpty) return;
        if (_targetHexes.isNotEmpty && !_targetHexes.contains(destHex)) return;

        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              text: text,
              sender: 'Via relay -> 0x$destHex',
              timestamp: DateTime.now(),
              isSystem: false,
            ),
          );
        });
        _scrollToBottom();
      }
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
    if (_targetHexes.isEmpty) {
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
    _messageController.clear();
    setState(() {
      _currentMessageLength = 0;
    });
    _scrollToBottom();

    try {
      var ackedCount = 0;
      var noAckCount = 0;
      var failedCount = 0;

      // Send to each valid group member (excluding self).
      for (final target in _targetHexes) {
        try {
          final query = <String, String>{'msg': messageText, 'to': target};
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
    } catch (e) {
      _updateOutgoingDeliveryStatus(outgoingIndex, MessageDeliveryStatus.failed);
      setState(() {
        _currentMessageLength = 0;
      });
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
                        return ChatBubble(message: _messages[index]);
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
                                maxLength: 50,
                                textCapitalization: TextCapitalization.sentences,
                                onChanged: (value) {
                                  setState(() {
                                    _currentMessageLength = value.length.clamp(0, 50);
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
                          '${_currentMessageLength} / 50',
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
