import 'package:flutter/material.dart';
import 'dart:async';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'group_details_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/local_database_service.dart';

class GroupsListScreen extends StatefulWidget {
  const GroupsListScreen({super.key});

  @override
  State<GroupsListScreen> createState() => _GroupsListScreenState();
}

class _GroupsListScreenState extends State<GroupsListScreen>
    with WidgetsBindingObserver {
  late Future<List<GroupSummaryRecord>> _groupsFuture;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _hasScrolled = false;
  Timer? _groupsSyncTimer;
  String _groupsFingerprint = '';
  bool _refreshInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _groupsFuture = LocalDatabaseService.instance.listGroups();
    _reloadGroups();
    _groupsSyncTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshGroupsIfChanged()),
    );
  }

  Future<void> _reloadGroups() async {
    try {
      final groups = await LocalDatabaseService.instance.listGroups();
      _groupsFingerprint = _fingerprintForGroups(groups);
      debugPrint('----------------- _reloadGroups Groups: ----------------------');
      debugPrint(
        '${groups.map((g) => '[id=${g.groupId}, uuid=${g.groupUuid}, name=${g.groupName}, members=${g.memberCount}]').join('\n')}',
      );
      
      if (!mounted) return;
      setState(() {
        _groupsFuture = Future.value(groups);
      });
    } catch (e) {
      debugPrint('Failed to reload groups: $e');
    }
  }

  String _fingerprintForGroups(List<GroupSummaryRecord> groups) {
    return groups
        .map(
          (g) =>
              '${g.groupId}|${g.groupUuid}|${g.groupName}|${g.memberCount}|${g.updatedAt}',
        )
        .join('||');
  }

  Future<void> _refreshGroupsIfChanged() async {
    if (_refreshInFlight) return;
    _refreshInFlight = true;
    try {
      final groups = await LocalDatabaseService.instance.listGroups();
      final nextFingerprint = _fingerprintForGroups(groups);
      if (nextFingerprint == _groupsFingerprint) return;
      _groupsFingerprint = nextFingerprint;
      if (!mounted) return;
      setState(() {
        debugPrint('----------------- _refreshGroupsIfChanged ----------------------');
        debugPrint('groups: $groups');
        _groupsFuture = Future.value(groups);
      });
    } catch (e) {
      debugPrint('Failed to refresh groups: $e');
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> _openCreateGroupScreen() async {
    final result = await Navigator.of(context).push<CreatedGroupPayload>(
      MaterialPageRoute(settings: const RouteSettings(name: 'create_group'),
        builder: (_) => const CreateGroupScreen(),
      ),
    );
    if (!mounted || result == null) return;
    await _reloadGroups();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(settings: const RouteSettings(name: 'group_chat'),
        builder: (_) => GroupChatScreen(
          key: ValueKey<int>(result.groupId),
          groupId: result.groupId,
          groupUuid: result.groupUuid.toString(),
          groupTitle: result.groupName,
        ),
      ),
    );
    if (!mounted) return;
    await _reloadGroups();
  }

  Future<void> _openGroupDetails(GroupSummaryRecord group) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(settings: const RouteSettings(name: 'group_details'),                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   
        builder: (_) => GroupDetailsScreen(groupId: group.groupId),
      ),
    );
    if (!mounted) return;
    if (removed == true) {
      await _reloadGroups();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _groupsSyncTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refreshGroupsIfChanged());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('groups')),
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
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Container(
            color: _hasScrolled
                ? Colors.transparent
                : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search groups',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),
        ),
      ),
      body: FutureBuilder<List<GroupSummaryRecord>>(
        future: _groupsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final groups = snapshot.data ?? const <GroupSummaryRecord>[];
          final normalizedQuery = _searchQuery.trim().toLowerCase();
          final filteredGroups = normalizedQuery.isEmpty
              ? groups
              : groups.where((group) {
                  final name = group.groupName.trim().toLowerCase();
                  return name.contains(normalizedQuery);
                }).toList();

          if (groups.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  AppLocalizations.of(context).tr('noGroups'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _reloadGroups,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                final scrolled = notification.metrics.pixels > 0;
                if (scrolled != _hasScrolled) {
                  setState(() => _hasScrolled = scrolled);
                }
                return false;
              },
              child: filteredGroups.isEmpty
                  ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 28,
                                vertical: 32,
                              ),
                              child: Text(
                                'No groups match your search',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: filteredGroups.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final group = filteredGroups[index];
                        final name = group.groupName.trim().isEmpty
                            ? 'Unnamed group'
                            : group.groupName.trim();
                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              Icons.group,
                              color: Theme.of(context).colorScheme.primary,
                              size: 28,
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
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => GroupChatScreen(
                                  key: ValueKey<int>(group.groupId),
                                  groupId: group.groupId,
                                  groupUuid: group.groupUuid,
                                  groupTitle: name,
                                ),
                              ),
                            );
                            if (!mounted) return;
                            await _reloadGroups();
                          },
                        );
                      },
                    ),
            ),
          );
        },
      ),
    );
  }
}
