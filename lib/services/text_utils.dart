import 'package:characters/characters.dart';

/// Shortens [text] to at most [maxChars] user-perceived characters, adding an
/// ellipsis when something was cut.
///
/// Counts grapheme clusters, so it never cuts an emoji or an accented letter in
/// half. A half emoji is an unpaired UTF-16 surrogate, and Flutter throws
/// "string is not well-formed UTF-16" when it tries to lay that out.
String truncateGraphemes(String text, int maxChars, {String ellipsis = '…'}) {
  if (maxChars <= 0) return '';
  final head = text.characters.take(maxChars + 1);
  if (head.length <= maxChars) return text;
  return '${head.take(maxChars - 1)}$ellipsis';
}

/// Replaces unpaired UTF-16 surrogates with U+FFFD so the string can be drawn.
///
/// Pastee 1.0 built titles with `substring`, which could split an emoji, so
/// saved data from that version may contain them.
String sanitizeUtf16(String text) {
  StringBuffer? out;
  final units = text.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    final isHigh = unit >= 0xD800 && unit <= 0xDBFF;
    final isLow = unit >= 0xDC00 && unit <= 0xDFFF;
    var broken = false;
    if (isHigh) {
      final next = i + 1 < units.length ? units[i + 1] : 0;
      if (next >= 0xDC00 && next <= 0xDFFF) {
        out?.writeCharCode(unit);
        out?.writeCharCode(next);
        i++;
        continue;
      }
      broken = true;
    } else if (isLow) {
      broken = true;
    }
    if (broken) {
      out ??= StringBuffer(String.fromCharCodes(units.sublist(0, i)));
      out.writeCharCode(0xFFFD);
    } else {
      out?.writeCharCode(unit);
    }
  }
  return out?.toString() ?? text;
}

/// The first non-empty line of [text], with runs of whitespace collapsed.
String firstLine(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed.replaceAll(RegExp(r'\s+'), ' ');
  }
  return '';
}

/// The title Pastee 1.0 generated: the first 30 UTF-16 units, newlines turned
/// into spaces. Used to tell auto-generated titles from ones the user typed.
String legacyAutoTitle(String content) {
  final head = content.length > 30 ? content.substring(0, 30) : content;
  return head.replaceAll('\n', ' ').trim();
}
