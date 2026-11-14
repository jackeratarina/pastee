import '../model/paste_item.dart';
import 'field_extractor.dart';
import 'masking.dart';
import 'text_utils.dart';

const int maxTitleLength = 40;

/// The title Pastee gives a new paste: its first non-empty line, with any
/// detected secret already turned into dots, so the password is never stored
/// in (or shown as) the title.
String autoTitle(String content) {
  final head = content.length > 4000 ? content.substring(0, 4000) : content;
  final extraction = FieldExtractor.extract(content);
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
      item.title == sanitizeUtf16(legacy);
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
