import 'package:flutter/material.dart';

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

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    try {
      final all = await LocalDatabaseService.instance.listContacts();
      final byAddress = <String, ContactRecord>{};
      for (final contact in all) {
        final key = _normalizeAddress(contact.loraAddress);
        if (key.isEmpty) continue;
        byAddress.putIfAbsent(key, () => contact);
      }
      if (!mounted) return;
      setState(() {
        _contacts = byAddress.values.toList()
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
      final ownerContactId = sortedSelected.first;
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
            child: TextField(
              controller: _nameController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'Enter group name',
                border: OutlineInputBorder(),
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
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final contact = _contacts[index];
                          final isSelected =
                              _selectedContactIds.contains(contact.id);
                          return CheckboxListTile(
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
                            title: Text(contact.displayName),
                            subtitle: Text(
                              '0x${_normalizeAddress(contact.loraAddress)}',
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
