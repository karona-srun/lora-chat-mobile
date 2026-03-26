import 'package:flutter/material.dart';

import '../models/status_detail_entry.dart';
import '../widgets/connection_details_widgets.dart';

class ConnectionDetailsScreen extends StatelessWidget {
  const ConnectionDetailsScreen({
    super.key,
    required this.displayName,
    required this.entries,
  });

  final String displayName;
  final List<StatusDetailEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection details'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          ConnectionDetailsHeaderCard(displayName: displayName),
          const SizedBox(height: 16),
          ConnectionDetailsEntriesList(entries: entries),
        ],
      ),
    );
  }
}
