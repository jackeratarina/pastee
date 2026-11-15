import '../model/field_config.dart';
import '../model/paste_item.dart';
import 'field_extractor.dart';
import 'masking.dart';
import 'text_utils.dart';

const int maxTitleLength = 40;

/// The title Pastee gives a new paste: its first non-empty line, with any
/// detected secret already turned into dots, so the password is never stored
/// in (or shown as) the title. [config] adds your own secret fields.
String autoTitle(String content, {FieldConfig? config}) {
  final head = content.length > 4000 ? content.substring(0, 4000) : content;
  final extraction = FieldExtractor.extract(content, config: config);
  final masked = Masker.apply(head, extraction.secretSpans);
  final line = firstLine(masked);
  return truncateGraphemes(line.isEmpty ? 'Untitled' : line, maxTitleLength);
}

/// Whether [item] still has a generated title (from this version or 1.0)
/// rather than one the user typed.
bool hasAutoTitle(PasteItem item) {
  final legacy = legacyAutoTitle(item.content);
  return item.title == autoTitle(item.content) ||
      item.title == legacy ||
      item.title == sanitizeUtf16(legacy) ||
      _isMaskedFirstLine(item.title, item.content);
}

/// Whether [title] is the content's first line with parts of it turned into
/// dots: a title generated while your own secret fields masked something,
/// with settings that may have changed since.
bool _isMaskedFirstLine(String title, String content) {
  if (!title.contains(Masker.dots[0])) return false;
  final head = content.length > 4000 ? content.substring(0, 4000) : content;
  final line = firstLine(
      Masker.apply(head, FieldExtractor.extract(content).secretSpans));
  var rest = title;
  final cut = rest.endsWith('…');
  if (cut) rest = rest.substring(0, rest.length - 1);

  // Split into plain text and runs of dots. A full mask (or one the length
  // limit cut short) stands for at least one character of the line; the plain
  // parts, and shorter runs of dots, must appear in order.
  final bullet = Masker.dots[0];
  final parts = RegExp('$bullet+|[^$bullet]+')
      .allMatches(rest)
      .map((m) => m.group(0)!)
      .toList();
  var at = 0;
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final last = i == parts.length - 1;
    if (part.startsWith(bullet) &&
        (part.length >= Masker.dots.length || (last && cut))) {
      at += 1;
      if (at > line.length) return false;
      continue;
    }
    if (i == 0) {
      if (!line.startsWith(part)) return false;
      at = part.length;
    } else if (last && !cut) {
      if (!line.endsWith(part) || line.length - part.length < at) return false;
      at = line.length;
    } else {
      final found = line.indexOf(part, at);
      if (found < 0) return false;
      at = found + part.length;
    }
  }
  return true;
}

/// The title to draw for [item].
///
/// When the item is hidden, detected secrets are masked in the title too, and
/// a "sensitive" item with a generated title shows a placeholder, since that
/// title is just the item's first line.
String displayTitle(PasteItem item, Extraction extraction,
    {required bool hidden}) {
  final title = sanitizeUtf16(item.title);
  if (!hidden) return title;
  if (item.sensitive && hasAutoTitle(item)) return 'Hidden item';
  return Masker.maskValues(title, extraction.secretValues);
}
