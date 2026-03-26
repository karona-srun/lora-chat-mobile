import 'package:flutter/material.dart';

class StatusDetailEntry {
  const StatusDetailEntry({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;
}
