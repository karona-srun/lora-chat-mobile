/// Firmware may put raw LoRa payloads in JSON string fields without escaping
/// ASCII controls; [jsonDecode] then throws [FormatException].
///
/// Walks the document toggling "string mode" on `"` (respecting `\`) and
/// rewrites U+0000–U+001F (except tab) as `\u00XX` inside strings only.
String sanitizeJsonControlCharsInStrings(String input) {
  final sb = StringBuffer();
  var inString = false;
  var esc = false;
  for (var i = 0; i < input.length; i++) {
    final unit = input.codeUnitAt(i);
    if (!inString) {
      sb.writeCharCode(unit);
      if (unit == 0x22) inString = true;
      continue;
    }
    if (esc) {
      sb.writeCharCode(unit);
      esc = false;
      continue;
    }
    if (unit == 0x5C) {
      sb.writeCharCode(unit);
      esc = true;
      continue;
    }
    if (unit == 0x22) {
      sb.writeCharCode(unit);
      inString = false;
      continue;
    }
    if (unit < 0x20 && unit != 0x09) {
      sb.write(r'\u');
      sb.write(unit.toRadixString(16).padLeft(4, '0'));
      continue;
    }
    sb.writeCharCode(unit);
  }
  return sb.toString();
}
