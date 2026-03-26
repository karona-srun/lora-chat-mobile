import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.onThemeChanged,
    this.onLanguageChanged,
  });

  final void Function(bool dark)? onThemeChanged;
  final void Function(bool isKhmer)? onLanguageChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _darkModeEnabled = false;
  bool _isKhmer = false; // false = English, true = Khmer
  bool _notificationsEnabled = true;
  bool _locationSharingEnabled = false;
  final TextEditingController _usernameController = TextEditingController();
  
  @override
  void initState() {
    super.initState();
    _loadThemePreference();
    _loadLocalePreference();
    _loadProfilePrefs();
  }

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final dark = prefs.getBool('dark_mode');
    if (dark != null && mounted) {
      setState(() => _darkModeEnabled = dark);
    }
  }

  Future<void> _loadLocalePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('locale');
    if (code != null && mounted) {
      setState(() => _isKhmer = code == 'km');
    }
  }

  Future<void> _setTheme(bool dark) async {
    setState(() => _darkModeEnabled = dark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', dark);
    widget.onThemeChanged?.call(dark);
  }

  Future<void> _setLanguage(bool isKhmer) async {
    setState(() => _isKhmer = isKhmer);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', isKhmer ? 'km' : 'en');
    widget.onLanguageChanged?.call(isKhmer);
  }

  Future<void> _loadProfilePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final username = (prefs.getString('callSign') ?? '').trim();

    if (!mounted) return;
    if (_usernameController.text != username) {
      setState(() {
        _usernameController.text = username;
        _usernameController.selection = TextSelection.collapsed(
          offset: _usernameController.text.length,
        );
      });
    }
  }

  Future<bool> _saveUsername() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty || username.length > 32) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid SSID length (1..32)'),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('device_ip')?.trim();
    final savedPort = prefs.getString('device_port')?.trim();
    final ip = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
    final port = (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';

    if (ip.isEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No connected device. Please set IP/Port first.'),
          backgroundColor: Colors.orange,
        ),
      );
      return false;
    }

    final baseUri = Uri.parse(port.isNotEmpty ? 'http://$ip:$port' : 'http://$ip');
    const setupPaths = <String>[
      '/setup/save',
      '/api/setup/save',
      '/setup',
    ];

    http.Response? okResponse;
    for (final path in setupPaths) {
      try {
        final response = await http
            .post(baseUri.replace(path: path), body: {'ssid_ap': username})
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw Exception('Connection timeout'),
            );
        if (response.statusCode == 200) {
          okResponse = response;
          break;
        }
      } catch (_) {
        // Try next endpoint candidate.
      }
    }

    if (okResponse == null) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to save SSID to device'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return false;
    }

    await prefs.setString('username', username);
    await prefs.setString('profile_username', username);

    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          okResponse.body.isNotEmpty
              ? okResponse.body
              : 'SSID saved to flash. Device restarting...',
        ),
      ),
    );
    return true;
  }

  Future<void> _changeUsername() async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tr('changeUsername')),
        content: TextField(
          controller: _usernameController,
          maxLines: 1,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) async {
            final saved = await _saveUsername();
            if (saved && context.mounted) {
              Navigator.of(context).pop();
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.tr('cancalButton')),
          ),
          TextButton(
            onPressed: () async {
              final saved = await _saveUsername();
              if (saved && context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: Text(l10n.tr('connectButton')),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tr('settings')), elevation: 0),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(0, 0, 0, 8),
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              l10n.tr('username'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 2),
                            Spacer(),
                            TextButton(
                              onPressed: () => _changeUsername(),
                              child: Text(
                                l10n.tr('changeUsername'),
                                style: TextStyle(
                                  color: Colors.blueAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
                          child: Text(
                            _usernameController.text,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
            child: Text(
              l10n.tr('appearance'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SwitchListTile.adaptive(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(l10n.tr('changeThemes')),
            subtitle: Text(
              _darkModeEnabled ? l10n.tr('darkMode') : l10n.tr('lightMode'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _darkModeEnabled,
            onChanged: (value) => _setTheme(value),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
            child: Text(
              l10n.tr('languages'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SwitchListTile.adaptive(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(l10n.tr('changeLanguages')),
            subtitle: Text(
              _isKhmer ? l10n.tr('khmer') : l10n.tr('english'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: _isKhmer,
            onChanged: (value) => _setLanguage(value),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
            child: Text(
              l10n.tr('preferences'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SwitchListTile.adaptive(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(l10n.tr('notifications')),
            subtitle: Text(
              l10n.tr('notificationsSubtitle'),
              style: const TextStyle(fontSize: 12),
            ),
            value: _notificationsEnabled,
            onChanged: (value) {
              setState(() {
                _notificationsEnabled = value;
              });
            },
          ),
          SwitchListTile.adaptive(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: Text(l10n.tr('locationSharing')),
            subtitle: Text(
              l10n.tr('locationSharingSubtitle'),
              style: const TextStyle(fontSize: 12),
            ),
            value: _locationSharingEnabled,
            onChanged: (value) {
              setState(() {
                _locationSharingEnabled = value;
              });
            },
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
            child: Text(
              l10n.tr('about'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.info, size: 20),
            title: Text(l10n.tr('appVersion')),
            subtitle: const Text('1.0.0', style: TextStyle(fontSize: 12)),
          ),
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.help, size: 20),
            title: Text(l10n.tr('helpSupport')),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l10n.tr('helpSupport'))));
            },
          ),
        ],
      ),
    );
  }
}
