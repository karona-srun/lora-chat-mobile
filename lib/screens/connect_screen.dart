import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';
import '../models/status_detail_entry.dart';
import '../utils/json_string_sanitize.dart';
import 'connection_details_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  Timer? _connectionCheckTimer;

  @override
  void initState() {
    super.initState();
    _refreshSavedConnection();
    _connectionCheckTimer = Timer.periodic(
      const Duration(seconds: 50),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _connectionCheckTimer?.cancel();
    super.dispose();
  }

  void _refreshConnectionStatus() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshSavedConnection() async {
    if (!mounted) return;
    setState(() {});
  }

  String _decodeResponseBody(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  Map<String, dynamic>? _asJsonMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  /// LoRa node [handleAPIStatus] JSON: `node`, `traffic`, `e22` (see firmware).
  Future<_StatusInfo?> _fetchStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim();
      final savedPort = prefs.getString('device_port')?.trim();

      final ip = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
      final port = (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';

      if (ip.isEmpty) return null;

      final baseUri = Uri.parse(
        port.isNotEmpty ? 'http://$ip:$port' : 'http://$ip',
      );

      http.Response? response;
      for (final path in ['/api/status', '/status']) {
        final r = await http.get(baseUri.replace(path: path)).timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw Exception('Connection timeout'),
            );
        if (r.statusCode == 200) {
          response = r;
          break;
        }
      }
      if (response == null) return null;

      final body = _decodeResponseBody(response);
      final trimmed = body.trimLeft();
      if (trimmed.startsWith('{')) {
        dynamic decoded;
        try {
          decoded = jsonDecode(body);
        } catch (_) {
          decoded = jsonDecode(sanitizeJsonControlCharsInStrings(body));
        }
        final root = _asJsonMap(decoded);
        if (root != null) {
          return _statusInfoFromDeviceJson(
            root,
            ip: ip,
            port: port,
            baseUri: baseUri,
          );
        }
      }

      // Legacy HTML status page
      final activeNodes = _extractSectionList(body, 'Synced Nodes');
      final nodeStatus = _extractNodeStatusConfig(body, activeNodes);
      final onlineNodesText = nodeStatus
          .firstWhere(
            (item) => item.label.toLowerCase() == 'active nodes',
            orElse: () => const _ConfigItem(label: 'active nodes', value: '0'),
          )
          .value;
      final onlineNodes =
          int.tryParse(onlineNodesText) ?? activeNodes.length;
      final address = _extractLiValue(body, 'Address');
      final channel = _extractLiValue(body, 'Channel');
      final e22Config = _extractE22Config(body);

      String displayName = 'LoRa node';
      if (address != null && address.isNotEmpty) {
        displayName = address;
      } else if (channel != null && channel.isNotEmpty) {
        displayName = 'CH $channel';
      } else {
        displayName = ip;
      }

      return _StatusInfo(
        displayName: displayName,
        endpoint: port.isNotEmpty ? '$ip:$port' : ip,
        onlineNodes: onlineNodes,
        activeNodes: activeNodes,
        nodeStatus: nodeStatus,
        e22Config: e22Config,
      );
    } catch (e) {
      debugPrint('Failed to load status: $e');
      return null;
    }
  }

  Future<_StatusInfo> _statusInfoFromDeviceJson(
    Map<String, dynamic> root, {
    required String ip,
    required String port,
    required Uri baseUri,
  }) async {
    final node = _asJsonMap(root['node']) ?? root;
    final traffic = _asJsonMap(root['traffic']) ?? root;
    final e22 = _asJsonMap(root['e22']);

    var onlineCount = 0;
    final activeNodes = <String>[];

    try {
      final nodesRes = await http.get(baseUri.replace(path: '/api/nodes')).timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw Exception('nodes timeout'),
          );
      if (nodesRes.statusCode == 200) {
        final nodesBody = _decodeResponseBody(nodesRes);
        dynamic nodesDecoded;
        try {
          nodesDecoded = jsonDecode(nodesBody);
        } catch (_) {
          try {
            nodesDecoded =
                jsonDecode(sanitizeJsonControlCharsInStrings(nodesBody));
          } catch (e) {
            debugPrint('Failed to parse /api/nodes JSON: $e');
            nodesDecoded = null;
          }
        }
        final nodesRoot = _asJsonMap(nodesDecoded);
        if (nodesRoot != null) {
          final oc = nodesRoot['onlineCount'];
          if (oc is num) onlineCount = oc.toInt();
          final list = nodesRoot['nodes'];
          if (list is List) {
            for (final item in list) {
              if (item is String) {
                final a = item.trim().toUpperCase();
                if (a.isNotEmpty) activeNodes.add('0x$a');
              } else {
                final m = _asJsonMap(item);
                final addr = m?['addr']?.toString().trim().toUpperCase();
                if (addr != null && addr.isNotEmpty) {
                  activeNodes.add('0x$addr');
                }
              }
            }
          }
          if (onlineCount == 0 && activeNodes.isNotEmpty) {
            onlineCount = activeNodes.length;
          }
        }
      }
    } catch (e) {
      debugPrint('Optional /api/nodes: $e');
    }

    void add(List<_ConfigItem> list, String label, String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      list.add(_ConfigItem(label: label, value: v));
    }

    final nodeStatus = <_ConfigItem>[];

    final myAddr = (node['myAddr']?.toString().trim().toUpperCase() ?? '');
    if (myAddr.isNotEmpty) {
      add(nodeStatus, 'Address', '0x$myAddr');
    }

    final channel = node['channel']?.toString().trim().toUpperCase() ?? '';
    if (channel.isNotEmpty) {
      add(nodeStatus, 'Channel', channel.length <= 2 ? '0x$channel' : channel);
    }

    add(nodeStatus, 'Active nodes', '$onlineCount');

    add(nodeStatus, 'Uptime', node['uptime']?.toString() ?? '');
    add(nodeStatus, 'Battery', '${node['battery']?.toString() ?? ''}%');
    add(nodeStatus, 'Charging', node['charging'] == true ? 'Yes' : 'No');

    final ready = node['ready'];
    if (ready is bool) {
      add(nodeStatus, 'Ready', ready ? 'Yes' : 'No');
    }
    add(nodeStatus, 'Status', node['status']?.toString() ?? '');
    add(nodeStatus, 'IP', node['ip']?.toString() ?? '');

    final target = node['targetAddr']?.toString().trim().toUpperCase() ?? '';
    if (target.isNotEmpty) add(nodeStatus, 'Target address', '0x$target');

    final rep = node['repeaterAddr']?.toString().trim().toUpperCase() ?? '';
    if (rep.isNotEmpty) add(nodeStatus, 'Repeater address', '0x$rep');

    final netId = node['netId']?.toString().trim().toUpperCase() ?? '';
    if (netId.isNotEmpty) add(nodeStatus, 'Network ID', '0x$netId');

    final useRep = node['useRepeater'];
    if (useRep is bool) {
      add(nodeStatus, 'Use repeater', useRep ? 'Yes' : 'No');
    }

    final sent = traffic['sent'];
    if (sent != null) add(nodeStatus, 'Messages sent', sent.toString());
    final received = traffic['received'];
    if (received != null) {
      add(nodeStatus, 'Messages received', received.toString());
    }
    add(nodeStatus, 'Last sent', traffic['lastSent']?.toString() ?? '');
    add(nodeStatus, 'Last received', traffic['lastReceived']?.toString() ?? '');

    if (activeNodes.isNotEmpty) {
      nodeStatus.add(
        _ConfigItem(label: 'Synced nodes', value: activeNodes.join(', ')),
      );
    }

    final e22Config = <_ConfigItem>[];
    if (e22 != null && e22['ok'] == true) {
      const e22Labels = <String, String>{
        'addh': 'ADDH',
        'addl': 'ADDL',
        'netid': 'NET ID',
        'chan': 'Channel (E22)',
        'uartBaudRate': 'UART baud rate',
        'airDataRate': 'Air data rate',
        'uartParity': 'UART parity',
        'subPacketSetting': 'Sub-packet setting',
        'rssiAmbientNoise': 'RSSI ambient noise',
        'transmissionPower': 'TX power',
        'enableRSSI': 'RSSI enabled',
        'lastSignalRssi': 'Last signal RSSI',
        'fixedTransmission': 'Fixed transmission',
        'enableRepeater': 'Repeater enabled',
        'enableLBT': 'LBT enabled',
        'worTransceiverControl': 'WOR transceiver',
        'worPeriod': 'WOR period',
      };
      final keys = e22.keys.where((k) => k != 'ok').toList()..sort();
      for (final key in keys) {
        final label = e22Labels[key] ?? key;
        e22Config.add(
          _ConfigItem(label: label, value: e22[key].toString()),
        );
      }
    }

    // save call sign to shared preferences
    final prefs = await SharedPreferences.getInstance();
    final nextCallSign = node['callSign']?.toString().trim() ?? '';
    final currentCallSign = prefs.getString('callSign')?.trim() ?? '';
    
    if (nextCallSign != currentCallSign) {
      await prefs.setString('callSign', nextCallSign);
    }

    final displayName =
        myAddr.isNotEmpty ? '${node['callSign']?.toString().trim().toUpperCase() ?? ''}' : '';

    return _StatusInfo(
      displayName: displayName,
      endpoint: port.isNotEmpty ? '$ip:$port' : ip,
      onlineNodes: onlineCount,
      activeNodes: activeNodes,
      nodeStatus: nodeStatus,
      e22Config: e22Config,
    );
  }

  String _stripHtml(String input) {
    var output = input;
    output = output.replaceAll(RegExp(r'<[^>]*>', multiLine: true), '');
    output = output
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return output.trim();
  }

  String? _extractLiValue(String html, String label) {
    final escaped = RegExp.escape(label);
    final match = RegExp(
      '<li>\\s*$escaped\\s*:\\s*<b>(.*?)</b>\\s*</li>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final raw = match?.group(1);
    if (raw == null) return null;
    final cleaned = _stripHtml(raw);
    return cleaned.isEmpty ? null : cleaned;
  }

  List<String> _extractSectionList(String html, String heading) {
    final escaped = RegExp.escape(heading);
    final sectionMatch = RegExp(
      '<h3>\\s*$escaped\\s*</h3>\\s*<ul>(.*?)</ul>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final sectionHtml = sectionMatch?.group(1);
    if (sectionHtml == null || sectionHtml.isEmpty) return const [];

    final items = <String>[];
    final liMatches = RegExp(
      '<li>(.*?)</li>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(sectionHtml);
    for (final match in liMatches) {
      final value = _stripHtml(match.group(1) ?? '');
      if (value.isEmpty || value.toLowerCase().contains('no nodes')) continue;
      items.add(value);
    }
    return items;
  }

  List<_ConfigItem> _extractE22Config(String html) {
    final sectionMatch = RegExp(
      '<h3>\\s*E22\\s+Config\\s*</h3>\\s*<ul>(.*?)</ul>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    final sectionHtml = sectionMatch?.group(1);
    if (sectionHtml == null || sectionHtml.isEmpty) return const [];

    final items = <_ConfigItem>[];
    final liMatches = RegExp(
      '<li>\\s*(.*?)\\s*:\\s*<b>(.*?)</b>\\s*</li>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(sectionHtml);
    for (final match in liMatches) {
      final key = _stripHtml(match.group(1) ?? '');
      final value = _stripHtml(match.group(2) ?? '');
      if (key.isNotEmpty && value.isNotEmpty) {
        items.add(_ConfigItem(label: key, value: value));
      }
    }
    return items;
  }

  List<_ConfigItem> _extractNodeStatusConfig(
    String html,
    List<String> activeNodes,
  ) {
    const labels = <String>[
      'Address',
      'Channel',
      'Uptime',
      'Sync scan',
      'Active nodes',
      'Battery',
      'Charging',
      'Last Rx',
      'Last Rx RSSI',
      'Last status',
    ];

    final items = <_ConfigItem>[];
    for (final label in labels) {
      final value = _extractLiValue(html, label);
      if (value != null && value.isNotEmpty) {
        items.add(_ConfigItem(label: label, value: value));
      }
    }
    if (activeNodes.isNotEmpty) {
      items.add(
        _ConfigItem(label: 'Synced nodes', value: activeNodes.join(', ')),
      );
    }
    return items;
  }

  IconData _configIconForLabel(String label) {
    final key = label.toLowerCase();
    if (key.contains('address')) return Icons.badge_outlined;
    if (key.contains('channel')) return Icons.settings_input_antenna;
    if (key.contains('fixed mode')) return Icons.swap_horiz;
    if (key.contains('rssi')) return Icons.network_cell;
    if (key.contains('power')) return Icons.bolt_outlined;
    if (key.contains('air rate')) return Icons.speed;
    if (key.contains('raw')) return Icons.data_object;
    return Icons.tune;
  }

  IconData _statusIconForLabel(String label) {
    final key = label.toLowerCase();
    if (key.contains('address')) return Icons.badge_outlined;
    if (key.contains('channel')) return Icons.settings_input_antenna;
    if (key.contains('uptime')) return Icons.timer_outlined;
    if (key.contains('sync')) return Icons.sync;
    if (key.contains('active nodes')) return Icons.hub_outlined;
    if (key.contains('battery')) return Icons.battery_full;
    if (key.contains('charging')) return Icons.bolt_outlined;
    if (key.contains('last rx rssi')) return Icons.network_cell;
    if (key.contains('last received')) return Icons.download_done_outlined;
    if (key.contains('last sent')) return Icons.upload_outlined;
    if (key.contains('messages received')) return Icons.inbox_outlined;
    if (key.contains('messages sent')) return Icons.outbox_outlined;
    if (key.contains('last rx')) return Icons.message_outlined;
    if (key.contains('last status')) return Icons.info_outline;
    if (key.contains('synced nodes')) return Icons.device_hub;
    if (key == 'ready') return Icons.power_settings_new;
    if (key == 'status') return Icons.info_outline;
    if (key == 'ip') return Icons.wifi_tethering;
    if (key.contains('target address')) return Icons.person_pin_outlined;
    if (key.contains('repeater address')) return Icons.repeat;
    if (key.contains('network id')) return Icons.numbers;
    if (key.contains('use repeater')) return Icons.repeat_one;
    return Icons.info_outline;
  }

  String _statusValueForLabel(_StatusInfo status, String label) {
    final match = status.nodeStatus.where(
      (item) => item.label.toLowerCase() == label.toLowerCase(),
    );
    if (match.isEmpty) return '-';
    return match.first.value;
  }

  List<_InfoEntry> _summaryInfoEntries(_StatusInfo status) {
    return <_InfoEntry>[
      _InfoEntry(
        icon: Icons.router,
        label: 'Endpoint',
        value: status.endpoint,
      ),
      _InfoEntry(
        icon: Icons.badge_outlined,
        label: 'Address',
        value: _statusValueForLabel(status, 'Address'),
      ),
      _InfoEntry(
        icon: Icons.settings_input_antenna,
        label: 'Channel',
        value: _statusValueForLabel(status, 'Channel'),
      ),
      _InfoEntry(
        icon: Icons.hub_outlined,
        label: 'Active nodes',
        value: _statusValueForLabel(status, 'Active nodes'),
      ),
      _InfoEntry(
        icon: Icons.timer_outlined,
        label: 'Uptime',
        value: _statusValueForLabel(status, 'Uptime'),
      ),
      _InfoEntry(
        icon: Icons.battery_full,
        label: 'Battery',
        value: _statusValueForLabel(status, 'Battery'),
      ),
      _InfoEntry(
        icon: Icons.bolt_outlined,
        label: 'Charging',
        value: _statusValueForLabel(status, 'Charging'),
      ),
    ];
  }

  List<_InfoEntry> _fullInfoEntries(_StatusInfo status) {
    final entries = <_InfoEntry>[
      _InfoEntry(
        icon: Icons.router,
        label: 'Endpoint',
        value: status.endpoint,
      ),
    ];

    entries.addAll(
      status.nodeStatus.map(
        (item) => _InfoEntry(
          icon: _statusIconForLabel(item.label),
          label: item.label,
          value: item.value,
        ),
      ),
    );

    entries.addAll(
      status.e22Config.map(
            (item) => _InfoEntry(
              icon: _configIconForLabel(item.label),
              label: item.label,
              value: item.value,
            ),
          ),
    );
    return entries;
  }

  Widget _buildStatusInfoGrid(BuildContext context, _StatusInfo status) {
    final entries = _summaryInfoEntries(status);
    final colorScheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useOneColumn = constraints.maxWidth < 300;
        final columns = useOneColumn ? 1 : 2;
        final spacing = 8.0;
        final itemWidth = columns == 2
            ? (constraints.maxWidth - spacing) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: spacing,
          runSpacing: 6,
          children: entries
              .map(
                (entry) => SizedBox(
                  width: itemWidth,
                  child: Row(
                    children: [
                      Icon(entry.icon, size: 13, color: colorScheme.primary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '${entry.label}: ${entry.value}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }

  void _openStatusDetails(_StatusInfo status) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConnectionDetailsScreen(
          displayName: status.displayName,
          entries: _fullInfoEntries(status)
              .map(
                (entry) => StatusDetailEntry(
                  icon: entry.icon,
                  label: entry.label,
                  value: entry.value,
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  String _badgeLabel(String value) {
    final text = value.trim();
    if (text.isEmpty) return '?';
    if (text.length <= 3) return text.toUpperCase();
    return text.substring(0, 3).toUpperCase();
  }

  Future<void> _clearSavedConnection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('device_ip');
    await prefs.remove('device_port');

    if (!mounted) return;
    setState(() {});

    // ScaffoldMessenger.of(context).showSnackBar(
    //   const SnackBar(
    //     content: Text('Saved connection removed'),
    //   ),
    // );
  }

  void _showConnectionOptions(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.wifi, size: 24),
                title: Text(l10n.tr('connectViaWiFi'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                subtitle: Text(l10n.tr('connectViaWiFiSubtitle'),
                  style: TextStyle(fontSize: 13),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _connectViaWiFi(context);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.bluetooth, size: 24),
                title: Text(l10n.tr('connectViaBluetooth'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  l10n.tr('connectViaBluetoothSubtitle'),
                  style: TextStyle(fontSize: 13),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _connectViaBluetooth(context);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _connectViaWiFi(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    // Load previously saved IP and port if available
    final prefs = await SharedPreferences.getInstance();
    final ipController = TextEditingController(
      text: prefs.getString('device_ip') ?? '192.168.4.1',
    );
    final portController = TextEditingController(
      text: prefs.getString('device_port') ?? '80',
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
          titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
          actionsPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          title: Text(l10n.tr('connectViaWiFi'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ipController,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'IP Address',
                  labelStyle: const TextStyle(fontSize: 13),
                  hintText: '192.168.1.1',
                  hintStyle: const TextStyle(fontSize: 13),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portController,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Port',
                  labelStyle: const TextStyle(fontSize: 13),
                  hintText: '4403',
                  hintStyle: const TextStyle(fontSize: 13),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                textStyle: const TextStyle(fontSize: 13),
              ),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.tr('cancalButton')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                textStyle: const TextStyle(fontSize: 13),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                ),
              ),
              onPressed: () async {
                final ip = ipController.text.trim();
                final port = portController.text.trim();

                if (ip.isEmpty || port.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please enter IP address and port'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                  return;
                }

                await prefs.setString('device_ip', ip);
                await prefs.setString('device_port', port);

                // Refresh saved connection in this screen
                await _refreshSavedConnection();

                if (context.mounted) {
                  Navigator.pop(context);
                  // ScaffoldMessenger.of(context).showSnackBar(
                  //   SnackBar(
                  //     content: Text('Saved connection: $ip:$port'),
                  //     backgroundColor: Colors.blue,
                  //   ),
                  // );
                }
              },
              child: Text(l10n.tr('connectButton')),
            ),
          ],
        );
      },
    );
  }

  void _connectViaBluetooth(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Scanning for Bluetooth devices...'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );
    // In a real app, you would implement Bluetooth scanning here
    Future.delayed(const Duration(seconds: 2), () {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Select Bluetooth Device'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: const Text('LoRa Device 1'),
                      subtitle: const Text('00:11:22:33:44:55'),
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Connecting to LoRa Device 1...'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: const Text('LoRa Device 2'),
                      subtitle: const Text('00:11:22:33:44:56'),
                      onTap: () {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Connecting to LoRa Device 2...'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).tr('connect')),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        children: [
          // Connection status card
          Container(
            // padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            // decoration: BoxDecoration(
            //   color: colorScheme.surfaceVariant.withOpacity(0.35),
            //   borderRadius: BorderRadius.circular(12),
            // ),
            child: Row(
              children: [
                // Icon(
                //   Icons.link_off,
                //   color: Colors.redAccent,
                //   size: 32,
                // ),
                // const SizedBox(width: 12),
                // const Expanded(
                //   child: Text(
                //     'No device connected',
                //     style: TextStyle(
                //       fontSize: 16,
                //       fontWeight: FontWeight.w600,
                //     ),
                //   ),
                // ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.tr('availableRadios'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Row(
                children: [
                  Icon(Icons.add, color: colorScheme.primary, size: 16),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: () {
                      _showConnectionOptions(context);
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(l10n.tr('manual')),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<SharedPreferences>(
            future: SharedPreferences.getInstance(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox.shrink();
              }
              final prefs = snapshot.data!;
              final ip = prefs.getString('device_ip')?.trim();
              final port = prefs.getString('device_port')?.trim();

              final hasSavedConnection =
                  ip != null &&
                  ip.isNotEmpty &&
                  port != null &&
                  port.isNotEmpty;

              if (hasSavedConnection) {
                // When we have a saved connection, check live status via /api/status (JSON).
                return FutureBuilder<_StatusInfo?>(
                  future: _fetchStatus(),
                  builder: (context, statusSnap) {
                    final status = statusSnap.data;
                    final isConnected =
                        statusSnap.hasData && status != null;
                    final isLoading = statusSnap.connectionState ==
                        ConnectionState.waiting;
                    if (isLoading && !statusSnap.hasData) {
                      return Card(
                        elevation: 1,
                        margin: const EdgeInsets.only(top: 8, bottom: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    return Card(
                      elevation: 1,
                      margin: const EdgeInsets.only(top: 8, bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,

                          children: [
                            Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colorScheme.primary.withOpacity(0.25),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                status != null
                                    ? _badgeLabel(status.displayName)
                                    : '?',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        isConnected
                                            ? Icons.check_circle
                                            : Icons.link_off,
                                        size: 16,
                                        color: isConnected
                                            ? Colors.green
                                            : Colors.redAccent,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          status != null
                                              ? status.displayName
                                              : 'Disconnected',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 20,
                                        ),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                        tooltip: 'Refresh connection',
                                        onPressed: _refreshConnectionStatus,
                                      ),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.delete_forever,
                                          size: 18,
                                          color: Colors.redAccent,
                                        ),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                        tooltip: 'Remove saved connection',
                                        onPressed: _clearSavedConnection,
                                      ),
                                    ],
                                  ),
                                  if (status != null) ...[
                                    const SizedBox(height: 4),
                                    _buildStatusInfoGrid(context, status),
                                    const SizedBox(height: 10),
                                    SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton(
                                        onPressed: () => _openStatusDetails(status),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 10,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          side: BorderSide(
                                            color: colorScheme.outlineVariant,
                                          ),
                                        ),
                                        child: Row(
                                          children: const [
                                            Icon(
                                              Icons.open_in_new,
                                              size: 17,
                                            ),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                'More details',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              Icons.arrow_forward_ios,
                                              size: 14,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              }

              // No saved connection yet: show helpful placeholder.
              return Container();
              // return Container(
              //   padding: const EdgeInsets.symmetric(
              //     horizontal: 12,
              //     vertical: 12,
              //   ),
              //   decoration: BoxDecoration(
              //     borderRadius: BorderRadius.circular(10),
              //     border: Border.all(
              //       color: colorScheme.outline.withOpacity(0.4),
              //     ),
              //   ),
              //   child: Column(
              //     crossAxisAlignment: CrossAxisAlignment.start,
              //     children: [
              //       Text(
              //         'No radios found nearby',
              //         style: Theme.of(context).textTheme.bodySmall,
              //       ),
              //       const SizedBox(height: 4),
              //       Text(
              //         'Turn on your LoRa device or use Manual to add one.',
              //         style: Theme.of(context).textTheme.bodySmall?.copyWith(
              //           color: colorScheme.onSurfaceVariant,
              //           fontSize: 12,
              //         ),
              //       ),
              //     ],
              //   ),
              // );
            },
          ),
        ],
      ),
    );
  }
}

class _StatusInfo {
  const _StatusInfo({
    required this.displayName,
    required this.endpoint,
    required this.onlineNodes,
    required this.activeNodes,
    required this.nodeStatus,
    required this.e22Config,
  });

  final String displayName;
  final String endpoint;
  final int onlineNodes;
  final List<String> activeNodes;
  final List<_ConfigItem> nodeStatus;
  final List<_ConfigItem> e22Config;
}

class _ConfigItem {
  const _ConfigItem({required this.label, required this.value});

  final String label;
  final String value;
}

class _InfoEntry {
  const _InfoEntry({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;
}
