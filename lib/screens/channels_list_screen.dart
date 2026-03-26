import 'package:flutter/material.dart';
import 'chat_detail_screen.dart';
import 'create_group_screen.dart';
import 'group_details_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/local_database_service.dart';

class ChannelsListScreen extends StatefulWidget {
  const ChannelsListScreen({super.key});

  @override
  State<ChannelsListScreen> createState() => _ChannelsListScreenState();
}

class _ChannelsListScreenState extends State<ChannelsListScreen> {
  late Future<List<GroupSummaryRecord>> _groupsFuture;

  @override
  void initState() {
    super.initState();
    _groupsFuture = LocalDatabaseService.instance.listGroups();
  }

  Future<void> _reloadGroups() async {
    setState(() {
      _groupsFuture = LocalDatabaseService.instance.listGroups();
    });
    await _groupsFuture;
  }

  Future<void> _openCreateGroupScreen() async {
    final result = await Navigator.of(context).push<CreatedGroupPayload>(
      MaterialPageRoute(
        builder: (_) => const CreateGroupScreen(),
      ),
    );
    if (!mounted || result == null) return;
    await _reloadGroups();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatDetailScreen(title: result.groupName),
      ),
    );
    if (!mounted) return;
    await _reloadGroups();
  }

  Future<void> _openGroupDetails(GroupSummaryRecord group) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GroupDetailsScreen(groupId: group.groupId),
      ),
    );
    if (!mounted) return;
    if (removed == true) {
      await _reloadGroups();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('channels')),
        elevation: 0,
        leading: IconButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          icon: const Icon(Icons.arrow_back_ios_new),
        ),
        actions: [
          IconButton(
            onPressed: _openCreateGroupScreen,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: FutureBuilder<List<GroupSummaryRecord>>(
        future: _groupsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final groups = snapshot.data ?? const <GroupSummaryRecord>[];
          if (groups.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  'No groups yet. Tap + to create a group.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _reloadGroups,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final group = groups[index];
                final name = group.groupName.trim().isEmpty
                    ? 'Unnamed group'
                    : group.groupName.trim();
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  leading: CircleAvatar(
                    radius: 16,
                    child: Text(
                      name[0].toUpperCase(),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    '${group.memberCount} members',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    onPressed: () => _openGroupDetails(group),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatDetailScreen(title: name),
                      ),
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }
}
