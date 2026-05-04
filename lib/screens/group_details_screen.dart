import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_database_service.dart';
import '../l10n/app_localizations.dart';

class GroupDetailsScreen extends StatefulWidget {
  const GroupDetailsScreen({super.key, required this.groupId});

  final int groupId;

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen>
    with WidgetsBindingObserver {
  GroupDetailsRecord? _details;
  List<ContactRecord> _contacts = const <ContactRecord>[];
  bool _loading = true;
  bool _removing = false;
  bool _updatingMembers = false;
  bool _canRemoveGroup = false;
  bool _editingGroupName = false;
  bool _savingGroupName = false;
  final TextEditingController _groupNameController = TextEditingController();

  Future<void> _showMessageDialog({required String message}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            AppLocalizations.of(context).tr('notification'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                AppLocalizations.of(context).tr('cancalButton'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadGroupDetails();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _groupNameController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_loading || _updatingMembers || _savingGroupName) return;
    unawaited(_loadGroupDetails());
  }

  String _normalizeAddress(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    // Match how other parts of the app normalize addresses (pad to 4 hex chars).
    if (text.isEmpty) return '';
    if (text.length <= 4 && RegExp(r'^[0-9A-F]+$').hasMatch(text)) {
      return text.padLeft(4, '0');
    }
    return text;
  }

  bool _isSelfPlaceholder(String loraAddress, String displayName) {
    final normalizedAddress = _normalizeAddress(loraAddress);
    final normalizedName = displayName.trim().toUpperCase();
    return normalizedAddress == '__SELF__' || normalizedName == '__SELF__';
  }

  bool _isHiddenContact(ContactRecord contact) {
    final normalizedAddress = _normalizeAddress(contact.loraAddress);
    final normalizedName = contact.displayName.trim().toUpperCase();
    return normalizedAddress == '__SELF__' || normalizedName == '__SELF__';
  }

  Future<bool> _computeCanRemoveGroup(GroupDetailsRecord details) async {
    // A group can be removed only by its owner.
    // We determine "owner == me" using a best-effort match:
    // - Prefer matching the owner member's stored address with our local `myAddr`.
    // - If the owner member is currently represented by the `__SELF__` placeholder
    //   (member hide behavior), fall back to enabling only when our own identity
    //   is not present via address/callSign in the group members list.
    final prefs = await SharedPreferences.getInstance();
    final myAddrPref =
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim();
    final myCallSign = (prefs.getString('callSign') ?? '').trim().toUpperCase();

    final selfAddr = _normalizeAddress(myAddrPref);
    final members = details.members;

    GroupMemberContactRecord? ownerMember;
    for (final m in members) {
      if (m.role == GroupMemberRole.owner) {
        ownerMember = m;
        break;
      }
    }
    if (ownerMember == null) return false;

    final ownerMatchesSelfAddr =
        selfAddr.isNotEmpty &&
        _normalizeAddress(ownerMember.loraAddress) == selfAddr;

    final selfAddrPresentInMembers =
        selfAddr.isNotEmpty &&
        members.any((m) => _normalizeAddress(m.loraAddress) == selfAddr);

    final selfCallSignPresentInMembers =
        myCallSign.isNotEmpty &&
        members.any((m) => m.displayName.trim().toUpperCase() == myCallSign);

    if (ownerMatchesSelfAddr) return true;

    final ownerIsSelfPlaceholder = _isSelfPlaceholder(
      ownerMember.loraAddress,
      ownerMember.displayName,
    );

    // If the owner is shown as `__SELF__`, treat it as "me" only when our own
    // identity isn't discoverable in the members list by address/callSign.
    if (ownerIsSelfPlaceholder &&
        !selfAddrPresentInMembers &&
        !selfCallSignPresentInMembers) {
      return true;
    }

    return false;
  }

  Future<void> _loadGroupDetails() async {
    setState(() => _loading = true);
    try {
      final details = await LocalDatabaseService.instance.getGroupDetails(
        widget.groupId,
      );
      final contacts = await LocalDatabaseService.instance.listContacts();
      if (!mounted) return;

      debugPrint('----------------- _loadGroupDetails details ----------------------');
      debugPrint('Details: ${details}');


      debugPrint('----------------- _loadGroupDetails ----------------------');
      debugPrint('Contacts: ${contacts.map((e) => e.displayName).join(', ')}');

      final canRemoveGroup = details == null
          ? false
          : await _computeCanRemoveGroup(details);
      setState(() {
        _details = details;
        _contacts = contacts;
        if (!_editingGroupName && details != null) {
          _groupNameController.text = details.groupName;
        }
        _canRemoveGroup = canRemoveGroup;
      });
    } catch (_) {
      if (!mounted) return;
      await _showMessageDialog(message: 'Failed to load group details');
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
        
    final filtered =
        _contacts.where((contact) {
          if (contact.id == null) return false;
          if (_isHiddenContact(contact)) return false;
          if (currentMemberIds.contains(contact.id)) return false;
          return true;
        }).toList()..sort(
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
                          child: Text(
                            AppLocalizations.of(context).tr('cancalButton'),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
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
                        label: Text(
                          AppLocalizations.of(context).tr('addMembers') +
                              ' (${selectedIds.length})',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
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
    final groupUuid = _details?.groupUuid;
    if (groupUuid == null || groupUuid.isEmpty) return;
    setState(() => _updatingMembers = true);
    try {
      for (final contactId in contactIds) {
        await LocalDatabaseService.instance.upsertGroupMember(
          GroupMemberRecord(
            groupUuid: groupUuid,
            contactId: contactId,
            role: GroupMemberRole.member,
            isActive: true,
          ),
        );
      }
      final refreshedDetails = await LocalDatabaseService.instance.getGroupDetails(
        widget.groupId,
      );
      if (refreshedDetails != null) {
        await _broadcastGroupInviteToAddedMembers(
          details: refreshedDetails,
          addedContactIds: contactIds,
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

  Future<void> _broadcastGroupInviteToAddedMembers({
    required GroupDetailsRecord details,
    required List<int> addedContactIds,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim() ?? '';
      final savedPort = prefs.getString('device_port')?.trim() ?? '';
      if (savedIp.isEmpty) return;

      final parsedPort = int.tryParse(savedPort);
      final uriBase = Uri(
        scheme: 'http',
        host: savedIp,
        port: parsedPort ?? 80,
        path: '/send',
      );

      String ownerAddr = '';
      for (final member in details.members) {
        if (member.role != GroupMemberRole.owner) continue;
        final normalized = _normalizeAddress(member.loraAddress);
        if (normalized.isNotEmpty &&
            normalized != '__SELF__' &&
            _isValidNodeAddress(normalized)) {
          ownerAddr = normalized;
          break;
        }
      }

      if (ownerAddr.isEmpty) {
        final myAddrPref =
            (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '')
                .trim();
        final fallbackOwner = _normalizeAddress(myAddrPref);
        if (_isValidNodeAddress(fallbackOwner)) {
          ownerAddr = fallbackOwner;
        } else {
          return;
        }
      }

      final allMemberAddrs = <String>{};
      for (final member in details.members) {
        final addr = _normalizeAddress(member.loraAddress);
        if (addr.isEmpty || addr == '__SELF__') continue;
        if (!_isValidNodeAddress(addr)) continue;
        allMemberAddrs.add(addr);
      }
      allMemberAddrs.add(ownerAddr);
      final membersCsv = allMemberAddrs.toList()..sort();

      final contactMap = <int, ContactRecord>{
        for (final contact in _contacts)
          if (contact.id != null) contact.id!: contact,
      };
      final inviteTargets = <String>{};
      for (final contactId in addedContactIds) {
        final contact = contactMap[contactId];
        if (contact == null) continue;
        final addr = _normalizeAddress(contact.loraAddress);
        if (addr.isEmpty || addr == '__SELF__') continue;
        if (!_isValidNodeAddress(addr)) continue;
        inviteTargets.add(addr);
      }
      if (inviteTargets.isEmpty) return;

      final payload =
          'GROUP_INVITE|${details.groupUuid}|${details.groupName}|$ownerAddr|${membersCsv.join(',')}';
      for (final target in inviteTargets) {
        try {
          final uri = uriBase.replace(
            queryParameters: <String, String>{'msg': payload, 'to': target},
          );
          await http.get(uri).timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best effort only: local add already completed.
        }
      }
    } catch (_) {
      // Best effort only: do not fail local member add.
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
          title: Text(
            AppLocalizations.of(context).tr('removeMember'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: Text(
            AppLocalizations.of(context)
                .tr('removeMemberConfirmation')
                .replaceAll('{name}', member.displayName),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                AppLocalizations.of(context).tr('cancalButton'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                AppLocalizations.of(context).tr('remove'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _updatingMembers = true);
    try {
      final groupUuid = _details?.groupUuid;
      if (groupUuid == null || groupUuid.isEmpty) return;
      await LocalDatabaseService.instance.upsertGroupMember(
        GroupMemberRecord(
          groupUuid: groupUuid,
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
      await _showMessageDialog(message: 'Failed to remove member');
    } finally {
      if (mounted) {
        setState(() => _updatingMembers = false);
      }
    }
  }

  Future<GroupMemberContactRecord?> _resolveSelfMember() async {
    final details = _details;
    if (details == null) return null;

    final prefs = await SharedPreferences.getInstance();
    final myAddrPref =
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim();
    final myCallSign = (prefs.getString('callSign') ?? '').trim().toUpperCase();
    final selfAddr = _normalizeAddress(myAddrPref);

    GroupMemberContactRecord? byAddr;
    if (selfAddr.isNotEmpty) {
      for (final m in details.members) {
        if (_normalizeAddress(m.loraAddress) == selfAddr) {
          byAddr = m;
          break;
        }
      }
      if (byAddr != null) return byAddr;
    }

    if (myCallSign.isNotEmpty) {
      for (final m in details.members) {
        if (m.displayName.trim().toUpperCase() == myCallSign) {
          return m;
        }
      }
    }
    return null;
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            AppLocalizations.of(context).tr('leaveGroup'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: Text(
            AppLocalizations.of(context).tr('leaveGroupConfirmation'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                AppLocalizations.of(context).tr('cancalButton'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                AppLocalizations.of(context).tr('leaveGroup'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _updatingMembers = true);
    try {
      final groupUuid = _details?.groupUuid;
      if (groupUuid == null || groupUuid.isEmpty) return;
      final selfMember = await _resolveSelfMember();
      if (selfMember == null) {
        await LocalDatabaseService.instance.removeGroup(widget.groupId);
        if (!mounted) return;
        // await _showMessageDialog(
        //   message: 'You have left the group.',
        // );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      await LocalDatabaseService.instance.upsertGroupMember(
        GroupMemberRecord(
          groupUuid: groupUuid,
          contactId: selfMember.contactId,
          role: selfMember.role,
          isActive: false,
        ),
      );

      // Verify we were removed from members.
      final refreshed = await LocalDatabaseService.instance.getGroupDetails(
        widget.groupId,
      );
      final stillMember =
          refreshed?.members.any(
            (m) =>
                m.contactId == selfMember.contactId &&
                m.role == selfMember.role,
          ) ??
          false;
      if (stillMember) {
        await LocalDatabaseService.instance.removeGroup(widget.groupId);
        if (!mounted) return;
        await _showMessageDialog(
          message: 'You have left the group.',
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
        return;
      }

      // Optional: broadcast leave so other devices also remove this member.
      if (refreshed != null) {
        await _broadcastGroupLeave(refreshed, selfMember);
      }

      if (!mounted) return;
      await _showMessageDialog(message: 'You have left the group.');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      await _showMessageDialog(message: 'Failed to leave group');
      
    } finally {
      if (mounted) {
        setState(() => _updatingMembers = false);
      }
    }
  }

  Future<void> _removeGroup() async {
    if (!_canRemoveGroup) {
      await _showMessageDialog(
        message: 'Only the group owner can remove this group.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            AppLocalizations.of(context).tr('removeGroup'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          content: Text(
            AppLocalizations.of(context).tr('removeGroupConfirmation'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(
                AppLocalizations.of(context).tr('cancalButton'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                AppLocalizations.of(context).tr('remove'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    setState(() => _removing = true);
    try {
      final details = _details;
      if (details != null) {
        await _broadcastGroupRemoval(details);
      }
      await LocalDatabaseService.instance.removeGroup(widget.groupId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      if (mounted) {
        setState(() => _removing = false);
      }
    }
  }

  bool _isValidNodeAddress(String value) {
    return RegExp(r'^[0-9A-F]{4,}$').hasMatch(value);
  }

  Future<List<String>> _groupRemovalTargets(GroupDetailsRecord details) async {
    final prefs = await SharedPreferences.getInstance();
    final myAddrPref =
        (prefs.getString('myAddr') ?? prefs.getString('my_addr') ?? '').trim();
    final selfAddr = _normalizeAddress(myAddrPref);

    final targets = <String>{};
    for (final member in details.members) {
      final addr = _normalizeAddress(member.loraAddress);
      if (addr.isEmpty || addr == '__SELF__') continue;
      if (!_isValidNodeAddress(addr)) continue;
      if (selfAddr.isNotEmpty && addr == selfAddr) continue;
      targets.add(addr);
    }
    return targets.toList()..sort();
  }

  Future<void> _broadcastGroupRemoval(GroupDetailsRecord details) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim() ?? '';
      final savedPort = prefs.getString('device_port')?.trim() ?? '';
      if (savedIp.isEmpty) return;

      final parsedPort = int.tryParse(savedPort);
      final uriBase = Uri(
        scheme: 'http',
        host: savedIp,
        port: parsedPort ?? 80,
        path: '/send',
      );

      final targets = await _groupRemovalTargets(details);
      if (targets.isEmpty) return;

      final payload = 'GROUP_REMOVE|${details.groupUuid}';
      for (final target in targets) {
        try {
          final uri = uriBase.replace(
            queryParameters: <String, String>{'msg': payload, 'to': target},
          );
          await http.get(uri).timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best effort: continue broadcasting to remaining members.
        }
      }
    } catch (_) {
      // Best effort: allow owner to remove local group even if broadcast fails.
    }
  }

  Future<void> _broadcastGroupLeave(
    GroupDetailsRecord details,
    GroupMemberContactRecord selfMember,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('device_ip')?.trim() ?? '';
      final savedPort = prefs.getString('device_port')?.trim() ?? '';
      if (savedIp.isEmpty) return;

      final parsedPort = int.tryParse(savedPort);
      final uriBase = Uri(
        scheme: 'http',
        host: savedIp,
        port: parsedPort ?? 80,
        path: '/send',
      );

      final selfAddr = _normalizeAddress(selfMember.loraAddress);
      final targets = <String>{};
      for (final member in details.members) {
        final addr = _normalizeAddress(member.loraAddress);
        if (addr.isEmpty || addr == '__SELF__') continue;
        if (!_isValidNodeAddress(addr)) continue;
        if (selfAddr.isNotEmpty && addr == selfAddr) continue;
        targets.add(addr);
      }
      if (targets.isEmpty) return;

      final payload =
          'GROUP_LEAVE|${details.groupUuid}|${selfMember.contactId.toString()}';
      for (final target in targets) {
        try {
          final uri = uriBase.replace(
            queryParameters: <String, String>{'msg': payload, 'to': target},
          );
          await http.get(uri).timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best effort only.
        }
      }
    } catch (_) {
      // Ignore broadcast errors; local leave already succeeded.
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
        title: Text(
          AppLocalizations.of(context).tr('groupDetails'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_ios_new),
        ),
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
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.45),
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
                                    AppLocalizations.of(
                                      context,
                                    ).tr('groupName'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: _savingGroupName
                                      ? null
                                      : _toggleGroupNameEditor,
                                  icon: Icon(
                                    _editingGroupName
                                        ? Icons.close
                                        : Icons.edit_outlined,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _editingGroupName
                                        ? AppLocalizations.of(
                                            context,
                                          ).tr('cancalButton')
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
                                  hintText: AppLocalizations.of(
                                    context,
                                  ).tr('groupNamePlaceholder'),
                                  isDense: true,
                                  filled: true,
                                  fillColor: Theme.of(
                                    context,
                                  ).colorScheme.surface,
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
                                    onPressed: _savingGroupName
                                        ? null
                                        : _updateGroupName,
                                    icon: _savingGroupName
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.save_outlined,
                                            size: 16,
                                          ),
                                    label: Text(
                                      _savingGroupName
                                          ? AppLocalizations.of(
                                              context,
                                            ).tr('updating')
                                          : AppLocalizations.of(
                                              context,
                                            ).tr('update'),
                                    ),
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
                        Text(
                          AppLocalizations.of(context).tr('noMembers'),
                          style: Theme.of(context).textTheme.bodySmall,
                        )
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
                                    _roleLabel(member.role).toString() ==
                                            "Owner"
                                        ? Icons.person
                                        : Icons.person_remove_alt_1,
                                    size: 20,
                                    color:
                                        _roleLabel(member.role).toString() ==
                                            "Owner"
                                        ? Colors.grey
                                        : Colors.redAccent,
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
                    child: _canRemoveGroup
                        ? ElevatedButton.icon(
                            onPressed: (_removing || _updatingMembers)
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
                            label: Text(
                              _removing
                                  ? AppLocalizations.of(context).tr('removing')
                                  : AppLocalizations.of(
                                      context,
                                    ).tr('removeGroup'),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: _leaveGroup,
                            icon: const Icon(Icons.person_remove_alt_1),
                            label: Text(
                              AppLocalizations.of(context).tr('leaveGroup'),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
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
