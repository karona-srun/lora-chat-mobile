import 'package:flutter/material.dart';
import 'chat_detail_screen.dart';
import '../l10n/app_localizations.dart';

class ChannelsListScreen extends StatelessWidget {
  const ChannelsListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chats = [
      'Mesh Group',
      'Nearby Nodes',
      'Emergency Channel',
      'Test Channel',
    ];

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
            onPressed: () {
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          ...chats.asMap().entries.map((entry) {
            final index = entry.key;
            final name = entry.value;
            return Column(
              children: [
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  leading: CircleAvatar(
                    radius: 16,
                    child: Text(
                      name[0],
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  subtitle: const Text(
                    'Last message preview...',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '12:30',
                        style: TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatDetailScreen(title: name),
                      ),
                    );
                  },
                ),
                if (index < chats.length - 1) const Divider(height: 1),
              ],
            );
          }),
        ],
      ),
    );
  }
}

