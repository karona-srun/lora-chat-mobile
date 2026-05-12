import 'dart:async';

import 'package:flutter/material.dart';
import 'contact_list_screen.dart';
import 'groups_list_screen.dart';
import '../l10n/app_localizations.dart';
import '../services/chat_unread_dot_service.dart';

class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key});

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> {
  bool _anyGroupUnread = false;
  bool _anyDirectUnread = false;
  Timer? _unreadPollTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_syncEntryUnread());
    _unreadPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_syncEntryUnread()),
    );
  }

  @override
  void dispose() {
    _unreadPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncEntryUnread() async {
    try {
      final g = await ChatUnreadDotService.hasAnyGroupUnread();
      final d = await ChatUnreadDotService.hasAnyDirectUnread();
      if (!mounted) return;
      if (g == _anyGroupUnread && d == _anyDirectUnread) return;
      setState(() {
        _anyGroupUnread = g;
        _anyDirectUnread = d;
      });
    } catch (_) {
      // Best effort.
    }
  }

  Widget _leadingWithDot({
    required BuildContext context,
    required IconData icon,
    required bool showDot,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            color: colorScheme.primary,
            size: 24,
          ),
        ),
        if (showDot)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: colorScheme.error,
                shape: BoxShape.circle,
                border: Border.all(
                  color: colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tr('messages')),
        elevation: 0,
      ),
      body: Column(
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: _leadingWithDot(
              context: context,
              icon: Icons.group,
              showDot: _anyGroupUnread,
            ),
            title: Text(
              AppLocalizations.of(context).tr('groups'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const GroupsListScreen(),
                ),
              );
            },
          ),
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: _leadingWithDot(
              context: context,
              icon: Icons.person,
              showDot: _anyDirectUnread,
            ),
            title: Text(
              AppLocalizations.of(context).tr('contacts'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ContactsListScreen(),
                ),
              );
            },
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceVariant.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        color: colorScheme.primary,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        l10n.tr('directMessages'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'You can send and receive channel (group chats) and direct messages. From any message you can long press to see available actions like copy, reply, tapback and delete as well as delivery details.',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
