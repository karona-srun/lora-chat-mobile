import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_detail_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/local_database_service.dart';
import '../utils/json_string_sanitize.dart';

/// Normalizes API `addr` (hex string or integer) to uppercase hex without 0x prefix.
String _normalizeNodeAddr(dynamic v) {
  if (v == null) return '';
  if (v is String) {
    var s = v.trim().toUpperCase();
    if (s.startsWith('0X')) s = s.substring(2);
    s = s.replaceAll(RegExp(r'[\s:-]'), '');
    if (s.isEmpty) return '';
    // Ignore placeholders/non-address values such as "__SELF__".
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(s)) return '';
    return s.length <= 4 ? s.padLeft(4, '0') : s;
  }
  if (v is num) {
    final n = v.toInt() & 0xFFFF;
    return n.toRadixString(16).toUpperCase().padLeft(4, '0');
  }
  return '';
}

String _fieldToString(dynamic v) {
  if (v == null) return '';
  return v.toString();
}

class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  late Future<List<_NodeEntry>> _nodesFuture;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _removedAddrs = <String>{};
  String? _selfContactId = "";

  Future<List<_NodeEntry>> _loadCachedContacts() async {
    try {
      final db = await LocalDatabaseService.instance.database;
      final rows = await db.query(
        'contacts',
        columns: ['lora_address', 'display_name'],
        orderBy: 'updated_at DESC, created_at DESC',
      );
      return rows
          .map((row) {
            final contact = ContactRecord.fromMap(row);
            final addr = _normalizeNodeAddr(contact.loraAddress);
            if (addr.isEmpty) return null;
            final name = contact.displayName.trim();
            return _NodeEntry(
              addr: addr,
              name: name.isNotEmpty ? name : '0x$addr',
              rssi: '',
              lastSeen: '',
              online: false,
              repeater: false,
              callSign: '',
              crypt: '',
              netId: '',
              channel: '',
            );
          })
          .whereType<_NodeEntry>()
          .toList();
    } catch (e) {
      debugPrint('Failed to load cached contacts: $e');
      return const [];
    }
  }

  Future<void> _saveContactsToLocal(List<_NodeEntry> nodes) async {
    if (nodes.isEmpty) return;
    try {
      for (final node in nodes) {
        await LocalDatabaseService.instance.upsertContact(
          ContactRecord(
            loraAddress: node.addr,
            displayName: node.name.trim().isEmpty
                ? '0x${node.addr}'
                : node.name,
          ),
        );
      }
    } catch (e) {
      debugPrint('Failed to save contacts locally: $e');
    }
  }

  Future<void> _initializeSelfContactId() async {
    final prefs = await SharedPreferences.getInstance();
    final myAddr = prefs.getString('myAddr')?.trim() ?? '';
    setState(() {
      _selfContactId = myAddr;
    });
  }

  @override
  void initState() {
    super.initState();
    _nodesFuture = _fetchNodes();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.trim());
    });
    _initializeSelfContactId();
  }



  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_NodeEntry>> _fetchNodes() async {
    try {
      final cachedNodes = await _loadCachedContacts();
      final mergedByAddr = <String, _NodeEntry>{
        for (final node in cachedNodes) node.addr: node,
      };

      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();

      final ip = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
      final port = (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';

      if (ip.isEmpty) {
        for (final addr in _removedAddrs) {
          mergedByAddr.remove(addr);
        }
        return mergedByAddr.values.toList();
      }

      final uri = Uri.parse(
        port.isNotEmpty ? 'http://$ip:$port/api/nodes' : 'http://$ip/api/nodes',
      );
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw Exception('Connection timeout'),
          );

      if (response.statusCode != 200) {
        for (final addr in _removedAddrs) {
          mergedByAddr.remove(addr);
        }
        return mergedByAddr.values.toList();
      }

      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      dynamic raw;
      try {
        raw = jsonDecode(body);
      } catch (_) {
        try {
          raw = jsonDecode(sanitizeJsonControlCharsInStrings(body));
        } catch (e) {
          debugPrint('Failed to parse /api/nodes JSON: $e');
          return const [];
        }
      }
      final parsed = <_NodeEntry>[];

      // LoRa node controller formats:
      // {"onlineCount":2,"nodes":["0001","0002"]}
      // {"onlineCount":2,"nodes":[{"addr":"0004","netId":"01","channel":41,"rssi":0,"lastSeenMs":39410,"repeater":false,"online":true}, ...]}
      if (raw is Map<String, dynamic>) {
        final nodes = raw['nodes'];
        if (nodes is List) {
          for (final item in nodes) {
            if (item is String) {
              final addr = _normalizeNodeAddr(item);
              if (addr.isEmpty) continue;
              parsed.add(
                _NodeEntry(
                  addr: addr,
                  name: '0x$addr',
                  rssi: '',
                  lastSeen: '',
                  online: true,
                  repeater: false,
                  callSign: '',
                  crypt: '',
                  netId: '',
                  channel: '',
                ),
              );
              continue;
            }
            if (item is! Map) continue;
            final m = Map<String, dynamic>.from(item);
            final addr = _normalizeNodeAddr(m['addr']);
            if (addr.isEmpty) continue;
            final callSign = (m['callSign'] as String?)?.trim() ?? '';
            final nickname = (m['nickname'] as String?)?.trim() ?? '';
            final crypt = _fieldToString(m['crypt']).trim();
            final netId = _fieldToString(m['netId']).trim();
            final channel = _fieldToString(m['channel']).trim();
            final displayName = callSign.isNotEmpty
                ? callSign
                : (nickname.isNotEmpty ? nickname : '0x$addr');
            parsed.add(
              _NodeEntry(
                addr: addr,
                name: displayName,
                rssi: _fieldToString(m['rssi']),
                lastSeen: _fieldToString(m['lastSeenMs']),
                online: m['online'] == true,
                repeater: m['repeater'] == true,
                callSign: callSign,
                crypt: crypt,
                netId: netId,
                channel: channel,
              ),
            );
          }
        }
      }

      // Backward compatibility with older list/object format:
      // [{"id":1,"nickname":"A","rssi":"-80"}]
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item);
          final addr = _normalizeNodeAddr(m['addr']);
          if (addr.isEmpty) continue;
          final nickname = (m['nickname'] as String?)?.trim() ?? '';
          final rssi = _fieldToString(m['rssi']);
          final callSignL = (m['callSign'] as String?)?.trim() ?? '';
          final displayName = callSignL.isNotEmpty
              ? callSignL
              : (nickname.isNotEmpty ? nickname : 'Node $addr');
          parsed.add(
            _NodeEntry(
              addr: addr,
              name: displayName,
              rssi: rssi,
              lastSeen: _fieldToString(m['lastSeenMs']),
              online: m['online'] == true,
              repeater: m['repeater'] == true,
              callSign: callSignL,
              crypt: _fieldToString(m['crypt']).trim(),
              netId: _fieldToString(m['netId']).trim(),
              channel: _fieldToString(m['channel']).trim(),
            ),
          );
        }
      }

      await _saveContactsToLocal(parsed);

      for (final node in parsed) {
        mergedByAddr[node.addr] = node;
      }

      for (final addr in _removedAddrs) {
        mergedByAddr.remove(addr);
      }

      return mergedByAddr.values.toList();
    } catch (e) {
      debugPrint('Failed to load nodes: $e');
      final cached = await _loadCachedContacts();
      return cached.where((n) => !_removedAddrs.contains(n.addr)).toList();
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _nodesFuture = _fetchNodes();
    });
    await _nodesFuture;
  }

  Future<void> _removeContact(_NodeEntry node) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Remove contact'),
          content: Text('Remove ${node.name} (0x${node.addr}) from contacts?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      final db = await LocalDatabaseService.instance.database;
      await db.delete(
        'contacts',
        where: 'lora_address = ?',
        whereArgs: [node.addr],
      );
      _removedAddrs.add(node.addr);
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Contact removed')));
    } catch (e) {
      debugPrint('Failed to remove contact: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to remove contact'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Up to 3 letters (e.g. "BBS") like the reference list row.
  static String _avatarLetters(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final words = trimmed.split(RegExp(r'\s+'));
    if (words.length >= 2) {
      final buf = StringBuffer();
      for (final w in words) {
        if (w.isEmpty) continue;
        final ch = w[0];
        if (RegExp(r'[a-zA-Z0-9]').hasMatch(ch)) {
          buf.write(ch.toUpperCase());
        }
        if (buf.length >= 3) break;
      }
      if (buf.length >= 2) return buf.toString();
    }
    final alnum = trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (alnum.isEmpty) return trimmed[0].toUpperCase();
    return alnum.length <= 3
        ? alnum.toUpperCase()
        : alnum.substring(0, 3).toUpperCase();
  }

  /// API `lastSeenMs` is age since last beacon (milliseconds), not epoch time.
  static String _formatNodeLastSeen(_NodeEntry node) {
    if (node.lastSeen.isEmpty) {
      return node.online ? 'Active now' : 'Offline';
    }
    final ms = int.tryParse(node.lastSeen);
    if (ms != null) {
      final sec = ms ~/ 1000;
      if (sec < 60) return 'Seen ${sec}s ago';
      final min = sec ~/ 60;
      if (min < 60) return 'Seen ${min}m ago';
      final h = min ~/ 60;
      return 'Seen ${h}h ago';
    }
    return 'Last seen ${node.lastSeen}';
  }

  static String _hexByteLabel(String raw) {
    if (raw.isEmpty) return '';
    var t = raw.toUpperCase().trim();
    if (t.startsWith('0X')) t = t.substring(2);
    t = t.replaceAll(RegExp(r'[^0-9A-F]'), '');
    if (t.isEmpty) return '';
    return '0x${t.padLeft(2, '0')}';
  }

  static bool _cryptEnabled(String crypt) {
    final c = crypt.toLowerCase().trim();
    return c == 'enabled' || c == 'true' || c == '1' || c == 'on';
  }

  static String _networkSummary(_NodeEntry n) {
    final parts = <String>[];
    if (n.netId.isNotEmpty) {
      parts.add('Net ${_hexByteLabel(n.netId)}');
    }
    if (n.channel.isNotEmpty) {
      parts.add('CH ${_hexByteLabel(n.channel)}');
    }
    return parts.join(' · ');
  }

  Widget _buildContactCard(BuildContext context, _NodeEntry node) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    const mint = Color(0xFFD4F5E8);
    const moonCircle = Color(0xFFFFE8CC);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      shape: 
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey),
      ),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  ChatDetailScreen(title: node.name, targetNodeId: node.addr, selfContactId: _selfContactId),
            ),
          );
        },
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: mint,
                        child: Text(
                          _avatarLetters(node.name),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            node.online
                                ? Icons.online_prediction_rounded
                                : Icons.online_prediction_rounded,
                            size: 18,
                            color: node.online
                                ? const Color(0xFF2E7D32)
                                : muted,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            node.online ? 'Online' : 'Offline',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: node.online
                                  ? const Color(0xFF2E7D32)
                                  : muted,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                _cryptEnabled(node.crypt)
                                    ? Icons.lock_outline
                                    : Icons.lock_open_outlined,
                                size: 18,
                                color: _cryptEnabled(node.crypt)
                                    ? const Color(0xFF2E7D32)
                                    : const Color.fromARGB(255, 213, 157, 0),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        node.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: Colors.black87,
                                              height: 1.25,
                                            ),
                                      ),
                                      if (node.name.toUpperCase() !=
                                          '0X${node.addr}') ...[
                                        const SizedBox(width: 10),
                                        Text(
                                          '0x${node.addr}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: muted,
                                            height: 1.2,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        _meshMetaRow(
                          leading: Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: moonCircle,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.nights_stay_rounded,
                              size: 12,
                              color: Colors.deepOrange.shade700,
                            ),
                          ),
                          text: _formatNodeLastSeen(node),
                          mutedColor: muted,
                        ),
                        // if (_networkSummary(node).isNotEmpty) ...[
                        //   const SizedBox(height: 4),
                        //   _meshMetaRow(
                        //     leading: Icon(
                        //       Icons.hub_outlined,
                        //       size: 16,
                        //       color: muted,
                        //     ),
                        //     text: _networkSummary(node),
                        //     mutedColor: muted,
                        //   ),
                        // ],
                        const SizedBox(height: 4),
                        _meshMetaRow(
                          leading: Icon(
                            Icons.settings_remote_outlined,
                            size: 16,
                            color: muted,
                          ),
                          text: node.repeater
                              ? 'Role: Repeater'
                              : 'Role: Client',
                          mutedColor: muted,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.directions_run_rounded,
                              size: 17,
                              color: Colors.black87,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'RSSI: ',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: muted,
                                height: 1.2,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                node.rssi.isNotEmpty ? '${node.rssi} dBm' : '—',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                  height: 1.1,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: muted.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: 'Remove contact',
                icon: const Icon(Icons.delete_outline),
                color: Colors.redAccent,
                onPressed: () => _removeContact(node),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _meshMetaRow({
    required Widget leading,
    required String text,
    required Color mutedColor,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: 22, height: 22, child: Center(child: leading)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: mutedColor, height: 1.2),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('contacts')),
        elevation: 0,
        leading: IconButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.arrow_back_ios_new),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: l10n.tr('search'),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<_NodeEntry>>(
              future: _nodesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final nodes = snapshot.data ?? const <_NodeEntry>[];
                final q = _searchQuery.toLowerCase();
                final filtered = _searchQuery.isEmpty
                    ? nodes
                    : nodes.where((n) {
                        return n.name.toLowerCase().contains(q) ||
                            n.callSign.toLowerCase().contains(q) ||
                            '0x${n.addr}'.toLowerCase().contains(q) ||
                            n.addr.toLowerCase().contains(q);
                      }).toList();

                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 0,
                          ),
                          children: const [
                            SizedBox(height: 80),
                            Center(child: Text('No contacts found')),
                          ],
                        )
                      : ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 0,
                          ),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const SizedBox.shrink(),
                          itemBuilder: (context, index) {
                            final node = filtered[index];
                            return _buildContactCard(context, node);
                          },
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeEntry {
  const _NodeEntry({
    required this.addr,
    required this.name,
    required this.rssi,
    required this.lastSeen,
    required this.online,
    this.repeater = false,
    this.callSign = '',
    this.crypt = '',
    this.netId = '',
    this.channel = '',
  });

  final String addr;
  final String name;
  final String rssi;
  final String lastSeen;
  final bool online;
  final bool repeater;
  final String callSign;
  final String crypt;
  final String netId;
  final String channel;
}
