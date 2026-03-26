import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';
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
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isConnected = false;
  final List<ChatMessage> _messages = [];
  String deviceIp = ''; // Loaded from SharedPreferences
  String devicePort = ''; // Loaded from SharedPreferences
  Timer? _messagePollTimer;
  int _currentMessageLength = 0;
  String _lastRxText = '';
  String? _targetHex;
  List<_NearbyNode> _nearbyNodes = [];

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
    _loadConnectionPrefs().then((_) {
      if (mounted) _loadNearbyNodes();
    });

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

      if (!mounted) return;

      setState(() {
        deviceIp =
            (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        devicePort =
            (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';
        _isConnected = deviceIp.isNotEmpty;
      });
    } catch (e) {
      debugPrint('Failed to load connection prefs: $e');
    }
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

  String _normalizeNodeAddr(dynamic v) {
    if (v == null) return '';
    if (v is String) {
      var s = v.trim().toUpperCase();
      if (s.startsWith('0X')) s = s.substring(2);
      s = s.replaceAll(RegExp(r'[\s:-]'), '');
      if (s.isEmpty) return '';
      return s.length <= 4 ? s.padLeft(4, '0') : s;
    }
    if (v is num) {
      final n = v.toInt() & 0xFFFF;
      return n.toRadixString(16).toUpperCase().padLeft(4, '0');
    }
    return '';
  }

  Future<void> _loadNearbyNodes() async {
    if (!_isConnected || deviceIp.trim().isEmpty) return;
    try {
      final uri = _buildUri('/api/nodes');
      final response = await http.get(uri).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Connection timeout'),
      );
      if (!mounted || response.statusCode != 200) return;

      final body = _decodeResponseBody(response);
      dynamic raw;
      try {
        raw = jsonDecode(body);
      } catch (_) {
        try {
          raw = jsonDecode(sanitizeJsonControlCharsInStrings(body));
        } catch (_) {
          return;
        }
      }

      final list = <_NearbyNode>[];
      if (raw is Map<String, dynamic>) {
        final nodes = raw['nodes'];
        if (nodes is List) {
          for (final item in nodes) {
            if (item is String) {
              final a = _normalizeNodeAddr(item);
              if (a.isEmpty) continue;
              list.add(_NearbyNode(addr: a, title: '0x$a'));
            } else if (item is Map) {
              final m = Map<String, dynamic>.from(item);
              final a = _normalizeNodeAddr(m['addr']);
              if (a.isEmpty) continue;
              final cs = (m['callSign'] as String?)?.trim() ?? '';
              final title = cs.isNotEmpty ? cs : '0x$a';
              list.add(_NearbyNode(addr: a, title: title));
            }
          }
        }
      }

      if (mounted) setState(() => _nearbyNodes = list);
    } catch (e) {
      debugPrint('Failed to load /api/nodes: $e');
    }
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

  Future<void> _fetchMessages() async {
    if (!_isConnected || deviceIp.trim().isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final myCallSign = prefs.getString('callSign')?.trim().toUpperCase() ?? '';

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
          decodedRaw =
              jsonDecode(sanitizeJsonControlCharsInStrings(rawBody));
        } catch (e) {
          debugPrint('Failed to parse /api/status JSON: $e');
          return;
        }
      }
      if (decodedRaw is! Map<String, dynamic>) return;
      final decoded = decodedRaw;

      final traffic = _trafficFromStatus(decoded);

      final lastRx = traffic['lastReceived']?.toString().trim() ?? '';
      if (lastRx.isEmpty || lastRx == _lastRxText) return;

      // Discovery beacons — same as WebUI noise; do not show in chat.
      if (lastRx.startsWith('HELLO|')) {
        _lastRxText = lastRx;
        return;
      }

      // Ignore telemetry/noise frame pattern like `0|41|...`.
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
        if (fromHex.length == 4 && !_matchesTarget(fromHex)) return;

        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              text: text,
              sender: 'Node 0x$fromHex',
              timestamp: DateTime.now(),
              isSystem: false,
            ),
          );
        });
        _scrollToBottom();
        return;
      }

      // RELAY|DEST|payload — show payload; optional filter by dest in DM view.
      final relay = RegExp(
        r'^RELAY\|([0-9A-Fa-f]{4})\|(.+)$',
        caseSensitive: false,
      ).firstMatch(lastRx);
      if (relay != null) {
        final destHex = (relay.group(1) ?? '').toUpperCase();
        final text = (relay.group(2) ?? '').trim();
        if (text.isEmpty) return;
        final target = _targetHex;
        if (target != null &&
            destHex.toUpperCase() != target.toUpperCase()) {
          return;
        }
        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              text: text,
              sender: 'Via relay → 0x$destHex',
              timestamp: DateTime.now(),
              isSystem: false,
            ),
          );
        });
        _scrollToBottom();
        return;
      }

      // Plain LoRa payload (firmware stores raw `rc.data` in lastReceived).
      if (!mounted) return;
      setState(() {
        _messages.add(
          ChatMessage(
            text: lastRx,
            sender: myCallSign.isNotEmpty ? myCallSign : ' ',
            timestamp: DateTime.now(),
            isSystem: false,
          ),
        );
      });
      _scrollToBottom();
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

    try {
      final target = _targetHex;
      // Firmware handleSend: /send?msg=… optional &to=AABB (4 hex), optional relay.
      final query = <String, String>{'msg': messageText};
      if (target != null && target.isNotEmpty) {
        query['to'] = target;
      }

      final uri = _buildUri('/send', query);

      final response = await http.get(
        uri,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw Exception('Connection timeout'),
      );

      if (response.statusCode == 200) {
        setState(() {
          _messages.add(ChatMessage(
            text: messageText,
            sender: 'You',
            timestamp: DateTime.now(),
            isSystem: false,
          ));
          _currentMessageLength = 0;
        });

        _messageController.clear();
        _scrollToBottom();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message sent'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      } else {
        throw Exception(
            'Server returned: ${response.statusCode} - ${_decodeResponseBody(response)}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send message: ${e.toString()}'),
          backgroundColor: Colors.red,
        ),
      );
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
            const SizedBox(width: 10),
            ],
          )
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
                      return ChatBubble(message: _messages[index]);
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
                              maxLength: 200,
                              textCapitalization:
                                  TextCapitalization.sentences,
                              onChanged: (value) {
                                setState(() {
                                  _currentMessageLength =
                                      value.length.clamp(0, 200);
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
                        '${_currentMessageLength} / 200',
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
  }
}

class _NearbyNode {
  const _NearbyNode({required this.addr, required this.title});

  final String addr;
  final String title;
}

