import 'package:shared_preferences/shared_preferences.dart';

/// Persists which direct (by LoRa address) and group (by UUID) chats have unread
/// traffic so list rows can show an indicator. Cleared when the user opens the chat.
class ChatUnreadDotService {
  ChatUnreadDotService._();

  static const String _directKey = 'chat_unread_direct_addrs_v1';
  static const String _groupKey = 'chat_unread_group_uuids_v1';
  static const String changedAtMsKey = 'chat_unread_dots_changed_at_ms';

  static String normalizeAddr(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  static Future<void> _bumpSignal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(changedAtMsKey, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<Set<String>> directUnreadSet() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_directKey) ?? const <String>[];
    return list.map(normalizeAddr).where((e) => e.isNotEmpty).toSet();
  }

  static Future<Set<String>> groupUnreadSet() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_groupKey) ?? const <String>[];
    return list.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  }

  static Future<bool> hasAnyDirectUnread() async {
    final s = await directUnreadSet();
    return s.isNotEmpty;
  }

  static Future<bool> hasAnyGroupUnread() async {
    final s = await groupUnreadSet();
    return s.isNotEmpty;
  }

  static Future<void> markDirectUnread(String loraAddress) async {
    final addr = normalizeAddr(loraAddress);
    if (addr.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_directKey) ?? <String>[]);
    if (!list.contains(addr)) {
      list.add(addr);
      await prefs.setStringList(_directKey, list);
    }
    await _bumpSignal();
  }

  static Future<void> markGroupUnread(String groupUuid) async {
    final uuid = groupUuid.trim();
    if (uuid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_groupKey) ?? <String>[]);
    if (!list.contains(uuid)) {
      list.add(uuid);
      await prefs.setStringList(_groupKey, list);
    }
    await _bumpSignal();
  }

  static Future<void> clearDirectUnread(String loraAddress) async {
    final addr = normalizeAddr(loraAddress);
    if (addr.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_directKey) ?? <String>[])
      ..removeWhere((e) => normalizeAddr(e) == addr);
    await prefs.setStringList(_directKey, list);
    await _bumpSignal();
  }

  static Future<void> clearGroupUnread(String groupUuid) async {
    final uuid = groupUuid.trim();
    if (uuid.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_groupKey) ?? <String>[])
      ..removeWhere((e) => e.trim() == uuid);
    await prefs.setStringList(_groupKey, list);
    await _bumpSignal();
  }
}
