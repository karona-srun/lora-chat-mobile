class GroupWireUtils {
  static const int maxWireTokenLength = 8;

  static String createGroupUuid({
    required int ownerContactId,
    required DateTime now,
  }) {
    final owner = ownerContactId.toRadixString(36);
    final time = (now.toUtc().millisecondsSinceEpoch % 0x100000)
        .toRadixString(36)
        .padLeft(4, '0');
    return 'g$owner$time';
  }

  static String wireToken(String groupUuid) {
    final token = groupUuid.trim();
    if (token.length <= maxWireTokenLength) return token;
    return 'g${_fnv1a32(token).toRadixString(16).padLeft(8, '0').substring(0, 6)}';
  }

  static bool tokenMatchesGroup(String wireToken, String groupUuid) {
    final token = wireToken.trim();
    final uuid = groupUuid.trim();
    return token == uuid || token == GroupWireUtils.wireToken(uuid);
  }

  static int _fnv1a32(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
