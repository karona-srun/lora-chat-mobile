import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/local_database_service.dart';

class CreatedGroupPayload {
  const CreatedGroupPayload({
    required this.groupId,
    required this.groupName,
  });

  final int groupId;
  final String groupName;
}

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _nameController = TextEditingController();
  final Set<int> _selectedContactIds = <int>{};
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
    return text.replaceAll(RegExp(r'[\s:-]'), '');
  }

  bool _isHiddenMember(ContactRecord contact) {
    final normalizedAddress = _normalizeAddress(contact.loraAddress);
    final normalizedName = contact.displayName.trim().toUpperCase();
    return normalizedAddress == '__SELF__' || normalizedName == '__SELF__';
  }

  Future<int?> _resolveSelfContactId() async {
    final prefs = await SharedPreferences.getInstance();
    
    final myAddr = prefs.getString('myAddr').toString();
    final myCallSign = prefs.getString('callSign').toString();
  

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
    try {
      final sortedSelected = _selectedContactIds.toList()..sort();
      final ownerContactId = await _resolveSelfContactId();
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
      final groupId = await LocalDatabaseService.instance.createGroupWithMembers(
        groupName: groupName,
        ownerContactId: ownerContactId,
        memberContactIds: sortedSelected,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        CreatedGroupPayload(groupId: groupId, groupName: groupName),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to create group'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group'),
        actions: [
          TextButton(
            onPressed: (_isSubmitting || _isLoading) ? null : _createGroup,
            child: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create'),
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
                  labelText: 'Group name',
                  hintText: 'Enter group name',
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
                const Text(
                  'Select members',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text('(${_selectedContactIds.length} selected)'),
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
                              _selectedContactIds.contains(contact.id);
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
                                          _selectedContactIds.add(contact.id!);
                                        } else {
                                          _selectedContactIds.remove(contact.id!);
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
