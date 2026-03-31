import 'package:flutter/material.dart';
import '../services/local_database_service.dart';
import '../l10n/app_localizations.dart';

class GroupDetailsScreen extends StatefulWidget {
  const GroupDetailsScreen({
    super.key,
    required this.groupId,
  });

  final int groupId;

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  GroupDetailsRecord? _details;
  List<ContactRecord> _contacts = const <ContactRecord>[];
  bool _loading = true;
  bool _removing = false;
  bool _updatingMembers = false;
  bool _editingGroupName = false;
  bool _savingGroupName = false;
  final TextEditingController _groupNameController = TextEditingController();

  Future<void> _showMessageDialog({
    required String message,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context).tr('notification'), style: Theme.of(context).textTheme.titleLarge,),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(AppLocalizations.of(context).tr('cancalButton'), style: Theme.of(context).textTheme.bodyMedium,),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _loadGroupDetails();
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    super.dispose();
  }

  String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    return text.replaceAll(RegExp(r'[\s:-]'), '');
  }

  bool _isHiddenContact(ContactRecord contact) {
    final normalizedAddress = _normalizeAddress(contact.loraAddress);
    final normalizedName = contact.displayName.trim().toUpperCase();
    return normalizedAddress == '__SELF__' || normalizedName == '__SELF__';
  }

  Future<void> _loadGroupDetails() async {
    setState(() => _loading = true);
    try {
      final details = await LocalDatabaseService.instance.getGroupDetails(
        widget.groupId,
      );
      final contacts = await LocalDatabaseService.instance.listContacts();
      if (!mounted) return;
      setState(() {
        _details = details;
        _contacts = contacts;
        if (!_editingGroupName && details != null) {
          _groupNameController.text = details.groupName;
        }
      });
    } catch (_) {
      if (!mounted) return;
      await _showMessageDialog(
        message: 'Failed to load group details',
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<ContactRecord> _availableContactsToAdd() {
    final details = _details;
    if (details == null) return const <ContactRecord>[];
    final currentMemberIds = details.members
        .map((member) => member.contactId)
        .toSet();
    final filtered = _contacts.where((contact) {
      if (contact.id == null) return false;
      if (_isHiddenContact(contact)) return false;
      if (currentMemberIds.contains(contact.id)) return false;
      return true;
    }).toList()
      ..sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
          b.displayName.toLowerCase(),
        ),
      );
    return filtered;
  }

  Future<void> _showAddMembersSheet() async {
    if (_updatingMembers) return;
    final candidates = _availableContactsToAdd();
    if (candidates.isEmpty) {
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(content: Text('No available contacts to add')),
      // );
      return;
    }

    final selectedIds = <int>{};
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context).tr('addMembers'),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(AppLocalizations.of(context).tr('cancalButton'), style: Theme.of(context).textTheme.bodyMedium,),
                        ),
                      ],
                    ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final contact = candidates[index];
                          final contactId = contact.id!;
                          final checked = selectedIds.contains(contactId);
                          return CheckboxListTile(
                            dense: true,
                            value: checked,
                            title: Text(contact.displayName),
                            subtitle: Text('0x${contact.loraAddress}'),
                            onChanged: (value) {
                              setSheetState(() {
                                if (value == true) {
                                  selectedIds.add(contactId);
                                } else {
                                  selectedIds.remove(contactId);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : () async {
                                Navigator.of(sheetContext).pop();
                                await _addMembers(selectedIds.toList());
                              },
                        icon: const Icon(Icons.person_add_alt_1),
                        label: Text(AppLocalizations.of(context).tr('addMembers') + ' (${selectedIds.length})', style: Theme.of(context).textTheme.bodySmall,),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _addMembers(List<int> contactIds) async {
    if (contactIds.isEmpty) return;
    setState(() => _updatingMembers = true);
    try {
      for (final contactId in contactIds) {
        await LocalDatabaseService.instance.upsertGroupMember(
          GroupMemberRecord(
            groupId: widget.groupId,
            contactId: contactId,
            role: GroupMemberRole.member,
            isActive: true,
          ),
        );
      }
      await _loadGroupDetails();
      if (!mounted) return;
      // ScaffoldMessenger.of(context).showSnackBar(
      //   SnackBar(content: Text('${contactIds.length} member(s) added')),
      // );
    } catch (_) {
      if (!mounted) return;
      // ScaffoldMessenger.of(context).showSnackBar(
      //   const SnackBar(
      //     content: Text('Failed to add members'),
      //     backgroundColor: Colors.red,
      //   ),
      // );
    } finally {
      if (mounted) {
        setState(() => _updatingMembers = false);
      }
    }
  }

  Future<void> _removeMember(GroupMemberContactRecord member) async {
    if (_updatingMembers) return;
    if (member.role == GroupMemberRole.owner) {
      // await _showMessageDialog(message: 'Owner cannot be removed');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context).tr('removeMember'), style: Theme.of(context).textTheme.titleLarge,),
          content: Text(AppLocalizations.of(context).tr('removeMemberConfirmation').replaceAll('{name}', member.displayName), style: Theme.of(context).textTheme.bodyMedium,),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppLocalizations.of(context).tr('cancalButton'), style: Theme.of(context).textTheme.bodyMedium,),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(AppLocalizations.of(context).tr('remove'), style: Theme.of(context).textTheme.bodyMedium,),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _updatingMembers = true);
    try {
      await LocalDatabaseService.instance.upsertGroupMember(
        GroupMemberRecord(
          groupId: widget.groupId,
          contactId: member.contactId,
          role: member.role,
          isActive: false,
        ),
      );
      await _loadGroupDetails();
      if (!mounted) return;
      // await _showMessageDialog(message: 'Member removed');
    } catch (_) {
      if (!mounted) return;
      await _showMessageDialog(
        message: 'Failed to remove member',
      );
    } finally {
      if (mounted) {
        setState(() => _updatingMembers = false);
      }
    }
  }

  Future<void> _removeGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(AppLocalizations.of(context).tr('removeGroup'), style: Theme.of(context).textTheme.titleLarge,),
          content: Text(AppLocalizations.of(context).tr('removeGroupConfirmation'), style: Theme.of(context).textTheme.bodyMedium,),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(AppLocalizations.of(context).tr('cancalButton'), style: Theme.of(context).textTheme.bodyMedium,),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(AppLocalizations.of(context).tr('remove'), style: Theme.of(context).textTheme.bodyMedium,),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _removing = true);
    try {
      await LocalDatabaseService.instance.removeGroup(widget.groupId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _removing = false);
      await _showMessageDialog(
        message: 'Failed to remove group',
      );
    }
  }

  String _roleLabel(GroupMemberRole role) {
    switch (role) {
      case GroupMemberRole.owner:
        return 'Owner';
      case GroupMemberRole.admin:
        return 'Admin';
      case GroupMemberRole.member:
        return 'Member';
    }
  }

  void _toggleGroupNameEditor() {
    if (_savingGroupName || _details == null) return;
    setState(() {
      _editingGroupName = !_editingGroupName;
      if (_editingGroupName) {
        _groupNameController.text = _details!.groupName;
      }
    });
  }

  Future<void> _updateGroupName() async {
    final details = _details;
    if (details == null || _savingGroupName) return;
    final nextName = _groupNameController.text.trim();
    if (nextName.isEmpty) {
      await _showMessageDialog(message: 'Group name cannot be empty');
      return;
    }
    if (nextName == details.groupName.trim()) {
      setState(() => _editingGroupName = false);
      return;
    }

    setState(() => _savingGroupName = true);
    try {
      await LocalDatabaseService.instance.upsertGroup(
        GroupRecord(
          id: details.groupId,
          groupUuid: details.groupUuid,
          groupName: nextName,
          ownerContactId: details.ownerContactId,
          createdAt: details.createdAt,
        ),
      );
      await _loadGroupDetails();
      if (!mounted) return;
      setState(() {
        _editingGroupName = false;
      });
    } catch (_) {
      if (!mounted) return;
      await _showMessageDialog(message: 'Failed to update group name');
    } finally {
      if (mounted) {
        setState(() => _savingGroupName = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).tr('groupDetails'), style: Theme.of(context).textTheme.titleLarge,),
        actions: [
          IconButton(
            onPressed: _updatingMembers || _loading || _details == null
                ? null
                : _showAddMembersSheet,
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: AppLocalizations.of(context).tr('addMembers'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _details == null
              ? const Center(child: Text('Group not found'))
              : Column(
                  children: [
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outlineVariant,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        AppLocalizations.of(context).tr('groupName'),
                                        style: Theme.of(context).textTheme.labelLarge,
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: _savingGroupName
                                          ? null
                                          : _toggleGroupNameEditor,
                                      icon: Icon(
                                        _editingGroupName ? Icons.close : Icons.edit_outlined,
                                        size: 18,
                                      ),
                                      label: Text(
                                        _editingGroupName
                                            ? AppLocalizations.of(context).tr('cancalButton')
                                            : '',
                                      ),
                                    ),
                                  ],
                                ),
                                if (_editingGroupName) ...[
                                  TextField(
                                    controller: _groupNameController,
                                    enabled: !_savingGroupName,
                                    textInputAction: TextInputAction.done,
                                    onSubmitted: (_) => _updateGroupName(),
                                    decoration: InputDecoration(
                                      hintText: AppLocalizations.of(context).tr('groupNamePlaceholder'),
                                      isDense: true,
                                      filled: true,
                                      fillColor: Theme.of(context).colorScheme.surface,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 10,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Spacer(),
                                      FilledButton.icon(
                                        onPressed: _savingGroupName ? null : _updateGroupName,
                                        icon: _savingGroupName
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              )
                                            : const Icon(Icons.save_outlined, size: 16),
                                        label: Text(_savingGroupName ? AppLocalizations.of(context).tr('updating') : AppLocalizations.of(context).tr('update')),
                                      ),
                                    ],
                                  ),
                                ] else
                                  Text(
                                    _details!.groupName,
                                    style: Theme.of(context).textTheme.titleLarge,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '${AppLocalizations.of(context).tr('groupUuid')}: ${_details!.groupUuid}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${AppLocalizations.of(context).tr('members')} (${_details!.members.length})',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 8),
                          if (_details!.members.isEmpty)
                            Text(AppLocalizations.of(context).tr('noMembers'), style: Theme.of(context).textTheme.bodySmall,)
                          else
                            ..._details!.members.map(
                              (member) => ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: const CircleAvatar(
                                  radius: 16,
                                  child: Icon(Icons.person, size: 20),
                                ),
                                title: Text(member.displayName),
                                subtitle: Text('0x${member.loraAddress}'),
                                trailing: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_roleLabel(member.role)),
                                    IconButton(
                                      icon: Icon(
                                        _roleLabel(member.role).toString() == "Owner" ? Icons.person : Icons.person_remove_alt_1,
                                        size: 20,
                                        color: _roleLabel(member.role).toString() == "Owner" ? Colors.grey : Colors.redAccent,
                                      ),
                                      tooltip: 'Remove member',
                                      onPressed: _updatingMembers
                                          ? null
                                          : () => _removeMember(member),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SafeArea(
                      top: false,
                      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _removing || _updatingMembers
                              ? null
                              : _removeGroup,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: _removing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.delete_outline),
                          label: Text(_removing ? AppLocalizations.of(context).tr('removing') : AppLocalizations.of(context).tr('removeGroup'), 
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
