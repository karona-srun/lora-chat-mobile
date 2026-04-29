import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;

enum ChatType { direct, group }

enum GroupMemberRole { owner, admin, member }

enum DeliveryStatus { pending, sent, delivered, failed }

class ContactRecord {
  ContactRecord({
    this.id,
    required this.loraAddress,
    required this.displayName,
    this.avatarUrl,
    this.isBlocked = false,
    this.createdAt,
    this.updatedAt,
  });

  final int? id;
  final String loraAddress;
  final String displayName;
  final String? avatarUrl;
  final bool isBlocked;
  final String? createdAt;
  final String? updatedAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'lora_address': loraAddress,
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'is_blocked': isBlocked ? 1 : 0,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory ContactRecord.fromMap(Map<String, Object?> map) {
    return ContactRecord(
      id: map['id'] as int?,
      loraAddress: map['lora_address'] as String,
      displayName: map['display_name'] as String,
      avatarUrl: map['avatar_url'] as String?,
      isBlocked: (map['is_blocked'] as int? ?? 0) == 1,
      createdAt: map['created_at'] as String?,
      updatedAt: map['updated_at'] as String?,
    );
  }
}

class GroupRecord {
  GroupRecord({
    this.id,
    required this.groupUuid,
    required this.groupName,
    required this.ownerContactId,
    this.createdAt,
    this.updatedAt,
  });

  final int? id;
  final String groupUuid;
  final String groupName;
  final int ownerContactId;
  final String? createdAt;
  final String? updatedAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'group_uuid': groupUuid,
      'group_name': groupName,
      'owner_contact_id': ownerContactId,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory GroupRecord.fromMap(Map<String, Object?> map) {
    return GroupRecord(
      id: map['id'] as int?,
      groupUuid: map['group_uuid'] as String,
      groupName: map['group_name'] as String,
      ownerContactId: map['owner_contact_id'] as int,
      createdAt: map['created_at'] as String?,
      updatedAt: map['updated_at'] as String?,
    );
  }
}

class GroupMemberRecord {
  GroupMemberRecord({
    this.id,
    required this.groupUuid,
    required this.contactId,
    this.role = GroupMemberRole.member,
    this.joinedAt,
    this.isActive = true,
  });

  final int? id;
  final String groupUuid;
  final int contactId;
  final GroupMemberRole role;
  final String? joinedAt;
  final bool isActive;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'group_uuid': groupUuid,
      'contact_id': contactId,
      'role': role.name,
      'joined_at': joinedAt,
      'is_active': isActive ? 1 : 0,
    };
  }

  factory GroupMemberRecord.fromMap(Map<String, Object?> map) {
    return GroupMemberRecord(
      id: map['id'] as int?,
      groupUuid: map['group_uuid'] as String,
      contactId: map['contact_id'] as int,
      role: GroupMemberRole.values.firstWhere(
        (value) => value.name == (map['role'] as String? ?? 'member'),
        orElse: () => GroupMemberRole.member,
      ),
      joinedAt: map['joined_at'] as String?,
      isActive: (map['is_active'] as int? ?? 1) == 1,
    );
  }
}

class GroupSummaryRecord {
  GroupSummaryRecord({
    required this.groupId,
    required this.groupUuid,
    required this.groupName,
    required this.memberCount,
    required this.ownerContactId,
    required this.updatedAt,
  });

  final int groupId;
  final String groupUuid;
  final String groupName;
  final int memberCount;
  final int ownerContactId;
  final String updatedAt;
}

class GroupMemberContactRecord {
  GroupMemberContactRecord({
    required this.contactId,
    required this.displayName,
    required this.loraAddress,
    required this.role,
  });

  final int contactId;
  final String displayName;
  final String loraAddress;
  final GroupMemberRole role;
}

class GroupDetailsRecord {
  GroupDetailsRecord({
    required this.groupId,
    required this.groupUuid,
    required this.groupName,
    required this.ownerContactId,
    required this.createdAt,
    required this.members,
  });

  final int groupId;
  final String groupUuid;
  final String groupName;
  final int ownerContactId;
  final String createdAt;
  final List<GroupMemberContactRecord> members;
}

class MessageRecord {
  MessageRecord({
    this.id,
    required this.messageUuid,
    required this.chatType,
    required this.fromContactId,
    this.toContactId,
    this.groupId,
    required this.payload,
    this.payloadType = 'text',
    this.deliveryStatus = DeliveryStatus.pending,
    this.sentAt,
    this.receivedAt,
    this.createdAt,
  });

  final int? id;
  final String messageUuid;
  final ChatType chatType;
  final String fromContactId;
  final String? toContactId;
  final String? groupId;
  final String payload;
  final String payloadType;
  final DeliveryStatus deliveryStatus;
  final String? sentAt;
  final String? receivedAt;
  final String? createdAt;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'message_uuid': messageUuid,
      'chat_type': chatType.name,
      'from_contact_id': fromContactId,
      'to_contact_id': toContactId,
      'group_id': groupId,
      'payload': payload,
      'payload_type': payloadType,
      'delivery_status': deliveryStatus.name,
      'sent_at': sentAt,
      'received_at': receivedAt,
      'created_at': createdAt,
    };
  }

  factory MessageRecord.fromMap(Map<String, Object?> map) {
    return MessageRecord(
      id: map['id'] as int?,
      messageUuid: map['message_uuid'] as String,
      chatType: ChatType.values.firstWhere(
        (value) => value.name == (map['chat_type'] as String? ?? 'direct'),
        orElse: () => ChatType.direct,
      ),
      fromContactId: (map['from_contact_id'])?.toString() ?? '',
      toContactId: (map['to_contact_id'])?.toString(),
      groupId: (map['group_id'])?.toString(),
      payload: map['payload'] as String,
      payloadType: map['payload_type'] as String? ?? 'text',
      deliveryStatus: DeliveryStatus.values.firstWhere(
        (value) =>
            value.name == (map['delivery_status'] as String? ?? 'pending'),
        orElse: () => DeliveryStatus.pending,
      ),
      sentAt: map['sent_at'] as String?,
      receivedAt: map['received_at'] as String?,
      createdAt: map['created_at'] as String?,
    );
  }
}

class LocalDatabaseService {
  LocalDatabaseService._();

  static final LocalDatabaseService instance = LocalDatabaseService._();

  static const _dbName = 'lomhor_local.db';
  static const _dbVersion = 1;

  sqflite.Database? _database;

  Future<void> ensureInitialized() async {
    await database;
  }

  Future<sqflite.Database> get database async {
    if (_database != null) return _database!;
    _database = await _openDatabase();
    return _database!;
  }

  Future<sqflite.Database> _openDatabase() async {
    sqflite.DatabaseFactory factory = sqflite.databaseFactory;
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      sqflite_ffi.sqfliteFfiInit();
      factory = sqflite_ffi.databaseFactoryFfi;
    }

    final dbDirectory = await factory.getDatabasesPath();
    final dbPath = p.join(dbDirectory, _dbName);

    return factory.openDatabase(
      dbPath,
      options: sqflite.OpenDatabaseOptions(
        version: _dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON;');
        },
        onCreate: _createSchema,
      ),
    );
  }

  Future<void> _createSchema(sqflite.Database db, int version) async {
    await db.execute('''
CREATE TABLE contacts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lora_address TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  avatar_url TEXT,
  is_blocked INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
''');

    await db.execute('''
CREATE TABLE groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_uuid TEXT NOT NULL UNIQUE,
  group_name TEXT NOT NULL,
  owner_contact_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (owner_contact_id) REFERENCES contacts(id)
);
''');

    await db.execute('''
CREATE TABLE group_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL,
  contact_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at TEXT NOT NULL DEFAULT (datetime('now')),
  is_active INTEGER NOT NULL DEFAULT 1,
  UNIQUE (group_id, contact_id),
  FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE,
  FOREIGN KEY (contact_id) REFERENCES contacts(id) ON DELETE CASCADE
);
''');

    await db.execute('''
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_uuid TEXT NOT NULL UNIQUE,
  chat_type TEXT NOT NULL,
  from_contact_id TEXT NOT NULL,
  to_contact_id TEXT,
  group_id INTEGER,
  payload TEXT NOT NULL,
  payload_type TEXT NOT NULL DEFAULT 'text',
  delivery_status TEXT NOT NULL DEFAULT 'pending',
  sent_at TEXT,
  received_at TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  FOREIGN KEY (from_contact_id) REFERENCES contacts(id),
  FOREIGN KEY (to_contact_id) REFERENCES contacts(id),
  FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE
);
''');

    await db.execute(
      'CREATE INDEX idx_contacts_lora_address ON contacts(lora_address);',
    );
    await db.execute(
      'CREATE INDEX idx_group_members_group_id ON group_members(group_id);',
    );
    await db.execute(
      'CREATE INDEX idx_group_members_contact_id ON group_members(contact_id);',
    );
    await db.execute(
      'CREATE INDEX idx_messages_direct_chat ON messages(chat_type, from_contact_id, to_contact_id, created_at);',
    );
    await db.execute(
      'CREATE INDEX idx_messages_group_chat ON messages(chat_type, group_id, created_at);',
    );
    await db.execute(
      'CREATE INDEX idx_messages_delivery_status ON messages(delivery_status);',
    );
  }

  Future<int> upsertContact(ContactRecord contact) async {
    final db = await database;
    final existing = await db.query(
      'contacts',
      columns: ['id'],
      where: 'lora_address = ?',
      whereArgs: [contact.loraAddress],
      limit: 1,
    );

    if (existing.isEmpty) {
      return db.insert('contacts', {
        'lora_address': contact.loraAddress,
        'display_name': contact.displayName,
        'avatar_url': contact.avatarUrl,
        'is_blocked': contact.isBlocked ? 1 : 0,
      });
    }

    final id = existing.first['id'] as int;
    await db.update(
      'contacts',
      {
        'display_name': contact.displayName,
        'avatar_url': contact.avatarUrl,
        'is_blocked': contact.isBlocked ? 1 : 0,
        'updated_at': _now(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<int> upsertGroup(GroupRecord group) async {
    final db = await database;
    final existing = await db.query(
      'groups',
      columns: ['id'],
      where: 'group_uuid = ?',
      whereArgs: [group.groupUuid],
      limit: 1,
    );

    if (existing.isEmpty) {
      return db.insert('groups', {
        'group_uuid': group.groupUuid,
        'group_name': group.groupName,
        'owner_contact_id': group.ownerContactId,
      });
    }

    final id = existing.first['id'] as int;
    await db.update(
      'groups',
      {
        'group_name': group.groupName,
        'owner_contact_id': group.ownerContactId,
        'updated_at': _now(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<int> upsertGroupMember(GroupMemberRecord member) async {
    final db = await database;
    final normalizedGroupUuid = member.groupUuid.trim();
    if (normalizedGroupUuid.isEmpty) {
      throw ArgumentError('groupUuid is required');
    }
    final groups = await db.query(
      'groups',
      columns: ['id'],
      where: 'group_uuid = ?',
      whereArgs: [normalizedGroupUuid],
      limit: 1,
    );
    if (groups.isEmpty) {
      throw StateError('Group not found for uuid: $normalizedGroupUuid');
    }
    final groupId = groups.first['id'] as int;

    final existing = await db.query(
      'group_members',
      columns: ['id'],
      where: 'group_uuid = ? AND contact_id = ?',
      whereArgs: [groupId, member.contactId],
      limit: 1,
    );

    if (existing.isEmpty) {
      return db.insert('group_members', {
        'group_uuid': normalizedGroupUuid,
        'contact_id': member.contactId,
        'role': member.role.name,
        'is_active': member.isActive ? 1 : 0,
      });
    }

    final id = existing.first['id'] as int;
    await db.update(
      'group_members',
      {'role': member.role.name, 'is_active': member.isActive ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    return id;
  }

  Future<List<ContactRecord>> listContacts() async {
    final db = await database;
    final rows = await db.query(
      'contacts',
      orderBy: 'display_name COLLATE NOCASE ASC, lora_address ASC',
    );
    return rows.map(ContactRecord.fromMap).toList();
  }

  Future<int> createGroupWithMembers({
    required String groupName,
    required String groupUuid,
    required int ownerContactId,
    required List<String> memberContactIds,
  }) async {
    final db = await database;
    final uniqueMembers = <String>{...memberContactIds, ownerContactId.toString()}.toList();

    return db.transaction((txn) async {
      final groupId = await txn.insert('groups', {
        'group_uuid': groupUuid,
        'group_name': groupName.trim(),
        'owner_contact_id': ownerContactId,
      });
      for (final contactId in uniqueMembers) {
        await txn.insert(
          'group_members',
          {
            'group_id': groupId,
            'contact_id': contactId,
            'role': contactId == ownerContactId
                ? GroupMemberRole.owner.name
                : GroupMemberRole.member.name,
            'is_active': 1,
          },
          conflictAlgorithm: sqflite.ConflictAlgorithm.ignore,
        );
      }
      return groupId;
    });
  }

  Future<List<GroupSummaryRecord>> listGroups() async {
    final db = await database;
    final rows = await db.rawQuery('''
SELECT
  g.id AS group_id,
  g.group_uuid AS group_uuid,
  g.group_name AS group_name,
  g.owner_contact_id AS owner_contact_id,
  COALESCE(g.updated_at, g.created_at, '') AS updated_at,
  COUNT(gm.id) AS member_count
FROM groups g
LEFT JOIN group_members gm ON gm.group_id = g.id AND gm.is_active = 1
GROUP BY g.id
ORDER BY COALESCE(g.updated_at, g.created_at) DESC;
''');
    return rows.map((row) {
      return GroupSummaryRecord(
        groupId: row['group_id'] as int,
        groupUuid: row['group_uuid'] as String,
        groupName: row['group_name'] as String,
        memberCount: (row['member_count'] as int?) ?? 0,
        ownerContactId: row['owner_contact_id'] as int,
        updatedAt: (row['updated_at'] as String?) ?? '',
      );
    }).toList();
  }

  Future<GroupDetailsRecord?> getGroupDetails(int groupId) async {
    final db = await database;
    final groups = await db.query(
      'groups',
      where: 'id = ?',
      whereArgs: [groupId],
      limit: 1,
    );
    if (groups.isEmpty) return null;
    final group = GroupRecord.fromMap(groups.first);
    final membersRows = await db.rawQuery(
      '''
SELECT
  c.id AS contact_id,
  c.display_name AS display_name,
  c.lora_address AS lora_address,
  gm.role AS role
FROM group_members gm
INNER JOIN contacts c ON c.id = gm.contact_id
WHERE gm.group_id = ? AND gm.is_active = 1
ORDER BY
  CASE gm.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,
  c.display_name COLLATE NOCASE ASC;
''',
      [groupId],
    );

    return GroupDetailsRecord(
      groupId: group.id!,
      groupUuid: group.groupUuid,
      groupName: group.groupName,
      ownerContactId: group.ownerContactId,
      createdAt: group.createdAt ?? '',
      members: membersRows.map((row) {
        return GroupMemberContactRecord(
          contactId: row['contact_id'] as int,
          displayName: (row['display_name'] as String?) ?? '',
          loraAddress: (row['lora_address'] as String?) ?? '',
          role: GroupMemberRole.values.firstWhere(
            (value) => value.name == (row['role'] as String? ?? 'member'),
            orElse: () => GroupMemberRole.member,
          ),
        );
      }).toList(),
    );
  }

  Future<void> removeGroup(int groupId) async {
    final db = await database;
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
  }

  Future<void> removeGroupByUuid(String groupUuid) async {
    final normalized = groupUuid.trim();
    if (normalized.isEmpty) return;
    final db = await database;
    await db.delete(
      'groups',
      where: 'group_uuid = ?',
      whereArgs: [normalized],
    );
  }

  Future<void> deactivateGroupMemberByUuid({
    required String groupUuid,
    required int contactId,
  }) async {
    final normalized = groupUuid.trim();
    if (normalized.isEmpty) return;
    final db = await database;
    final groups = await db.query(
      'groups',
      columns: ['id'],
      where: 'group_uuid = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (groups.isEmpty) return;
    final groupId = groups.first['id'] as int;
    await db.update(
      'group_members',
      {'is_active': 0},
      where: 'group_id = ? AND contact_id = ?',
      whereArgs: [groupId, contactId],
    );
  }

  Future<String?> insertMessage(MessageRecord message) async {
    final db = await database;
    final resolvedFromContactId = await _resolveMessageContactId(
      rawValue: message.fromContactId,
      fallbackDisplayName: 'Node 0x${_normalizeAddressForContactLookup(message.fromContactId)}',
    );
    if (resolvedFromContactId == null) return null;
    final resolvedToContactId = await _resolveMessageContactId(
      rawValue: message.toContactId,
      fallbackDisplayName: 'Node 0x${_normalizeAddressForContactLookup(message.toContactId ?? '')}',
    );

    final insertedId = await db.insert('messages', {
      'message_uuid': message.messageUuid,
      'chat_type': message.chatType.name,
      'from_contact_id': resolvedFromContactId,
      'to_contact_id': resolvedToContactId,
      'group_id': message.groupId,
      'payload': message.payload,
      'payload_type': message.payloadType,
      'delivery_status': message.deliveryStatus.name,
      'sent_at': message.sentAt,
      'received_at': message.receivedAt,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    if (insertedId == 0) return null;
    return insertedId.toString();
  }

  String _normalizeAddressForContactLookup(String value) {
    var text = value.trim().toUpperCase();
    if (text.startsWith('0X')) text = text.substring(2);
    text = text.replaceAll(RegExp(r'[\s:-]'), '');
    if (text.isEmpty) return '';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(text)) return '';
    return text.length <= 4 ? text.padLeft(4, '0') : text;
  }

  Future<String?> _resolveMessageContactId({
    required String? rawValue,
    required String fallbackDisplayName,
  }) async {
    if (rawValue == null) return null;
    final normalized = rawValue.trim();
    if (normalized.isEmpty) return null;
    final db = await database;

    final parsedId = int.tryParse(normalized);
    if (parsedId != null) {
      final existingById = await db.query(
        'contacts',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [parsedId],
        limit: 1,
      );
      if (existingById.isNotEmpty) return parsedId.toString();
    }

    final normalizedAddr = _normalizeAddressForContactLookup(normalized);
    if (normalizedAddr.isEmpty) return null;
    final existingByAddr = await db.query(
      'contacts',
      columns: ['id'],
      where: 'lora_address = ?',
      whereArgs: [normalizedAddr],
      limit: 1,
    );
    if (existingByAddr.isNotEmpty) {
      final id = existingByAddr.first['id'] as int;
      return id.toString();
    }

    final createdId = await upsertContact(
      ContactRecord(
        loraAddress: normalizedAddr,
        displayName: fallbackDisplayName.trim().isEmpty
            ? 'Node 0x$normalizedAddr'
            : fallbackDisplayName.trim(),
      ),
    );
    return createdId.toString();
  }

  Future<bool> hasRecentDuplicateIncomingMessage({
    required ChatType chatType,
    required int fromContactId,
    int? toContactId,
    int? groupId,
    required String payload,
    Duration window = const Duration(seconds: 8),
  }) async {
    final db = await database;
    final normalizedPayload = payload.trim();
    if (normalizedPayload.isEmpty) return false;
    final cutoff = DateTime.now().toUtc().subtract(window).toIso8601String();

    final rows = await db.rawQuery(
      '''
SELECT id
FROM messages
WHERE chat_type = ?
  AND from_contact_id = ?
  AND payload = ?
  AND (received_at IS NOT NULL OR delivery_status = ?)
  AND COALESCE(received_at, created_at, '') >= ?
  AND (
    (? IS NULL AND to_contact_id IS NULL) OR to_contact_id = ?
  )
  AND (
    (? IS NULL AND group_id IS NULL) OR group_id = ?
  )
LIMIT 1;
''',
      [
        chatType.name,
        fromContactId,
        normalizedPayload,
        DeliveryStatus.delivered.name,
        cutoff,
        toContactId,
        toContactId,
        groupId,
        groupId,
      ],
    );
    return rows.isNotEmpty;
  }

  Future<void> updateMessageDeliveryStatus({
    required String messageUuid,
    required DeliveryStatus status,
  }) async {
    final db = await database;
    await db.update(
      'messages',
      {'delivery_status': status.name},
      where: 'message_uuid = ?',
      whereArgs: [messageUuid],
    );
  }

  Future<List<MessageRecord>> listDirectMessages({
    required String contactA,
    required String contactB,
    int? limit,
  }) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where:
          "chat_type = 'direct' AND ((from_contact_id = ? AND to_contact_id = ?) OR (from_contact_id = ? AND to_contact_id = ?))",
      whereArgs: [contactA, contactB, contactB, contactA],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    debugPrint('rows: ${rows.length}');
    return rows.map(MessageRecord.fromMap).toList();
  }

  /// Deletes all persisted direct messages between two contacts (both directions).
  Future<int> deleteDirectMessagesBetween({
    required String contactA,
    required String contactB,
  }) async {
    final db = await database;
    return db.delete(
      'messages',
      where:
          "chat_type = 'direct' AND ((from_contact_id = ? AND to_contact_id = ?) OR (from_contact_id = ? AND to_contact_id = ?))",
      whereArgs: [contactA, contactB, contactB, contactA],
    );
  }

  /// Deletes all persisted group chat messages for [groupId].
  Future<int> deleteGroupMessagesForGroup({required String groupId}) async {
    final db = await database;
    return db.delete(
      'messages',
      where: "chat_type = 'group' AND group_id = ?",
      whereArgs: [groupId],
    );
  }

  Future<List<MessageRecord>> listGroupMessages({
    required String groupUuid,
    int? limit,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
SELECT m.*
FROM messages m
INNER JOIN groups g ON g.id = m.group_id
WHERE m.chat_type = 'group' AND g.group_uuid = ?
ORDER BY m.created_at ASC
${limit != null ? 'LIMIT ?' : ''};
''',
      limit != null ? [groupUuid, limit] : [groupUuid],
    );
    return rows.map(MessageRecord.fromMap).toList();
  }

  Future<List<int>> listActiveGroupIdsForContact(int contactId) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
SELECT group_id
FROM group_members
WHERE contact_id = ? AND is_active = 1;
''',
      [contactId],
    );
    return rows
        .map((row) => row['group_id'])
        .whereType<int>()
        .toSet()
        .toList();
  }

  Future<List<int>> listActiveGroupIdsForMemberDisplayName(
    String displayName,
  ) async {
    final normalized = displayName.trim();
    if (normalized.isEmpty) return const <int>[];
    final db = await database;
    final rows = await db.rawQuery(
      '''
SELECT DISTINCT gm.group_id AS group_id
FROM group_members gm
INNER JOIN contacts c ON c.id = gm.contact_id
WHERE gm.is_active = 1
  AND TRIM(UPPER(c.display_name)) = TRIM(UPPER(?));
''',
      [normalized],
    );
    return rows
        .map((row) => row['group_id'])
        .whereType<int>()
        .toSet()
        .toList();
  }

  // get all messages by contact id
  Future<List<MessageRecord>> listMessagesByFromContactId(String contactId, String? toContactId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'from_contact_id = ? AND to_contact_id = ?',
      whereArgs: [contactId, toContactId],
    );
    debugPrint('rows: ${rows.length}');
    return rows.map(MessageRecord.fromMap).toList();
  }

  Future<void> close() async {
    final db = _database;
    if (db == null) return;
    await db.close();
    _database = null;
  }

  String _now() => DateTime.now().toUtc().toIso8601String();
}
