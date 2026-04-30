import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../services/local_database_service.dart';
import '../l10n/app_localizations.dart';

class CreatedGroupPayload {
  const CreatedGroupPayload({
    required this.groupId,
    required this.groupUuid,
    required this.groupName,
  });

  final int groupId;
  final String groupUuid;
  final String groupName;
}

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedContactIds = <String>{};
  List<ContactRecord> _contacts = const <ContactRecord>[];
  bool _isLoading = true;
  bool _isSubmitting = false;
  int? _selfContactId;
  String _selfCallSign = '';
  String _selfAddr = '';

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  bool _isHiddenMember(ContactRecord contact) {
    final normalizedAddress = _normalizeAddress(contact.loraAddress);
    final normalizedName = _normalizeAddress(contact.displayName);
    
    final isSystemSender =
        normalizedAddress.startsWith('__GROUP_SENDER') ||
        normalizedName.startsWith('__GROUP_SENDER');
    
    final isIncomingUnknown =
        normalizedAddress.startsWith('__INCOMING__UNKNOWN__') ||
        normalizedName.startsWith('__INCOMING__UNKNOWN__');

    return normalizedAddress == '__SELF__' ||
        normalizedName == '__SELF__' ||
        isSystemSender ||
        isIncomingUnknown;
  }

  Future<int?> _resolveSelfContactId() async {
    final prefs = await SharedPreferences.getInstance();
    final myAddr = _normalizeAddress(
      (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
    );
    final myCallSign = (prefs.getString('callSign') ?? '').trim();

    if (_selfContactId != null) return _selfContactId;
    if (myAddr.isEmpty) return null;

    // Ensure self contact exists in local DB so owner is always current user.
    final fallbackName = myCallSign.isNotEmpty
        ? myCallSign
        : '0x$myAddr';
    final resolvedId = await LocalDatabaseService.instance.upsertContact(
      ContactRecord(
        loraAddress: myAddr,
        displayName: fallbackName,
      ),
    );
    _selfContactId = resolvedId;
    return resolvedId;
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      _selfCallSign = (prefs.getString('callSign') ?? '').trim().toUpperCase();
      _selfAddr = _normalizeAddress(
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim(),
      );

      final all = await LocalDatabaseService.instance.listContacts();
      final byAddress = <String, ContactRecord>{};
      for (final contact in all) {
        final key = _normalizeAddress(contact.loraAddress);
        if (key.isEmpty) continue;
        byAddress.putIfAbsent(key, () => contact);
      }
      final uniqueContacts = byAddress.values.toList();
      ContactRecord? selfRecord;
      if (_selfAddr.isNotEmpty) {
        for (final contact in uniqueContacts) {
          if (_normalizeAddress(contact.loraAddress) == _selfAddr) {
            selfRecord = contact;
            break;
          }
        }
      }
      
      if (selfRecord == null && _selfCallSign.isNotEmpty) {
        for (final contact in uniqueContacts) {
          if (contact.displayName.trim().toUpperCase() == _selfCallSign) {
            selfRecord = contact;
            break;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _selfContactId = selfRecord?.id;
        _contacts = uniqueContacts
            .where(
              (contact) =>
                  contact.id != _selfContactId && !_isHiddenMember(contact),
            )
            .toList()
          ..sort(
            (a, b) => a.displayName.toLowerCase().compareTo(
                  b.displayName.toLowerCase(),
                ),
          );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to load contacts'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _createGroup() async {
    final groupName = _nameController.text.trim();
    debugPrint('----------------- _createGroup ----------------------');
    debugPrint('Group name: $groupName');
    if (groupName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name')),
      );
      return;
    }
    if (_selectedContactIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    debugPrint('Group name: $groupName');
    debugPrint('Selected contact IDs: ${_selectedContactIds.join(', ')}');

    try {
      final sortedSelected = _selectedContactIds.toList()..sort();
      debugPrint('Sorted selected: ${sortedSelected.join(', ')}');
      final ownerContactId = await _resolveSelfContactId();
      debugPrint('Owner contact ID: $ownerContactId');
      if (ownerContactId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to identify your account as group owner'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isSubmitting = false);
        return;
      }

      final groupUuid =
          'grp${ownerContactId.toString()}_${DateTime.now().toUtc().microsecondsSinceEpoch}';
      
      debugPrint('Group UUID: $groupUuid');

      // Convert selected addresses into DB contact ids before creating members.
      final selectedByAddress = _contacts
          .where(
            (c) =>
                _normalizeAddress(c.loraAddress).isNotEmpty &&
                _selectedContactIds.contains(_normalizeAddress(c.loraAddress)),
          )
          .toList();
      final resolvedMemberIds = <String>[];
      for (final contact in selectedByAddress) {
        final addr = _normalizeAddress(contact.loraAddress);
        if (addr.isEmpty) continue;
        final resolvedId = await LocalDatabaseService.instance.upsertContact(
          ContactRecord(
            loraAddress: addr,
            displayName:
                contact.displayName.trim().isNotEmpty ? contact.displayName.trim() : '0x$addr',
          ),
        );
        resolvedMemberIds.add(resolvedId.toString());
      }

      final groupId = await LocalDatabaseService.instance.createGroupWithMembers(
        groupName: groupName,
        groupUuid: groupUuid,
        ownerContactId: ownerContactId,
        memberContactIds: resolvedMemberIds,
      );

      try {
        final prefs = await SharedPreferences.getInstance();
        final savedIp = prefs.getString('device_ip')?.trim();
        final savedPort = prefs.getString('device_port')?.trim();
        final ownerAddr = _selfAddr.isNotEmpty
            ? _selfAddr
            : _normalizeAddress(
                (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '')
                    .trim(),
              );

        final ip = (savedIp != null && savedIp.isNotEmpty) ? savedIp : '';
        final port = (savedPort != null && savedPort.isNotEmpty) ? savedPort : '';

        if (ip.isNotEmpty) {
          final parsedPort = int.tryParse(port);
          final uriBase = Uri(
            scheme: 'http',
            host: ip,
            port: parsedPort ?? 80,
            path: '/send',
          );

          final selectedById = _contacts
              .where(
                (c) =>
                    _normalizeAddress(c.loraAddress).isNotEmpty &&
                    _selectedContactIds.contains(_normalizeAddress(c.loraAddress)),
              )
              .toList();
          final targetAddresses = selectedById
              .map((c) => _normalizeAddress(c.loraAddress))
              .where((addr) => addr.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

          if (targetAddresses.isNotEmpty && ownerAddr.isNotEmpty) {
            final ownerName = _selfCallSign.trim().isNotEmpty
                ? _selfCallSign.trim()
                : 'Owner';
            final allMemberAddresses = <String>{
              '$ownerName:$ownerAddr',
              ...selectedById.map((contact) {
                final name = contact.displayName.trim().isNotEmpty
                    ? contact.displayName.trim()
                    : 'Node';
                final addr = _normalizeAddress(contact.loraAddress);
                return '$name:$addr';
              }),
            }..removeWhere((member) => member.endsWith(':'));
            final invitePayload = StringBuffer()
              ..write('GROUP_INVITE|')
              ..write(groupUuid)
              ..write('|')
              ..write(groupName)
              ..write('|')
              ..write(ownerAddr)
              ..write('|')
              ..write(allMemberAddresses.join(','));

            // Broadcast once so all members can receive the same invite notification.
            try {
              final broadcastUri = uriBase.replace(
                queryParameters: <String, String>{
                  'msg': invitePayload.toString(),
                },
              );
              await http.get(broadcastUri).timeout(
                const Duration(seconds: 5),
              );
            } catch (_) {}

            for (final target in targetAddresses) {
              try {
                final uri = uriBase.replace(
                    queryParameters: <String, String>{
                    'msg': invitePayload.toString(),
                    'to': target,
                  },
                );
                await http.get(uri).timeout(
                  const Duration(seconds: 5),
                );
              } catch (_) {}
            }
            
          } else if (ownerAddr.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Missing owner address, invite not sent'),
                backgroundColor: Colors.orange,
              ),
            );
          } else if (selectedById.isNotEmpty && targetAddresses.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Selected members have invalid LoRa addresses'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(
        CreatedGroupPayload(
          groupId: groupId,
          groupUuid: groupUuid,
          groupName: groupName,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to create group'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _isSubmitting = false);
    }

    debugPrint('----------------- _createGroup ----------------------');
    debugPrint('Group created successfully');
    debugPrint('Group name: $groupName');
    debugPrint('Selected contact IDs: ${_selectedContactIds.join(', ')}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).tr('createGroup'), style: Theme.of(context).textTheme.titleLarge,),
        actions: [
          TextButton(
            onPressed: (_isSubmitting || _isLoading) ? null : _createGroup,
            child: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(AppLocalizations.of(context).tr('create'), style: Theme.of(context).textTheme.bodySmall,),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SizedBox(
              height: 50,
              child: TextField(
                controller: _nameController,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(context).tr('groupName'),
                  hintText: AppLocalizations.of(context).tr('groupNamePlaceholder'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  AppLocalizations.of(context).tr('selectMembers'),
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text('(${_selectedContactIds.length} ${AppLocalizations.of(context).tr('selected')})', style: Theme.of(context).textTheme.bodySmall,),
              ],
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _contacts.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            'No contacts found. Add contacts first from Direct Messages.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _contacts.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 0,
                          thickness: 0,
                          color: Colors.transparent,
                        ),
                        itemBuilder: (context, index) {
                          final contact = _contacts[index];
                          final isSelected =
                              _selectedContactIds.contains(_normalizeAddress(contact.loraAddress));
                          return SizedBox(
                            height: 52,
                            child: CheckboxListTile(
                              dense: true,
                              visualDensity: const VisualDensity(
                                vertical: -2,
                                horizontal: -1,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              value: isSelected,
                              onChanged: _isSubmitting
                                  ? null
                                  : (value) {
                                      if (contact.id == null) return;
                                      setState(() {
                                        if (value == true) {
                                          _selectedContactIds.add(_normalizeAddress(contact.loraAddress));
                                        } else {
                                          _selectedContactIds.remove(_normalizeAddress(contact.loraAddress));
                                        }
                                      });
                                    },
                              title: Text(
                                contact.displayName,
                                style: const TextStyle(fontSize: 14),
                              ),
                              subtitle: Text(
                                '0x${_normalizeAddress(contact.loraAddress)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
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
