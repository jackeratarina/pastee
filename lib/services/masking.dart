import 'field_extractor.dart';

/// A run of display text that is either shown as-is or replaced by dots.
final class MaskedSegment {
  const MaskedSegment(this.text, {this.masked = false});

  final String text;
  final bool masked;
}

/// Turns secrets into dots for display. Copying always uses the real values.
class Masker {
  Masker._();

  /// Every secret becomes the same number of dots, so the mask does not reveal
  /// how long the password is.
  static const String dots = '••••••••';

  /// Splits [text] into plain and masked segments. [spans] may be unsorted or
  /// overlapping, and may run past the end of [text] (they are clamped).
  static List<MaskedSegment> segments(String text, List<Span> spans) {
    if (spans.isEmpty) return [MaskedSegment(text)];
    final sorted = [...spans]..sort((a, b) => a.start.compareTo(b.start));
    final out = <MaskedSegment>[];
    var cursor = 0;
    for (final span in sorted) {
      final start = span.start.clamp(0, text.length);
      final end = span.end.clamp(0, text.length);
      if (end <= cursor) continue;
      if (start > cursor) {
        out.add(MaskedSegment(text.substring(cursor, start)));
        out.add(const MaskedSegment(dots, masked: true));
      } else if (out.isEmpty || !out.last.masked) {
        out.add(const MaskedSegment(dots, masked: true));
      }
      // Overlapping or touching secrets share one mask, so the dots don't
      // reveal how many there are.
      cursor = end;
    }
    if (cursor < text.length) out.add(MaskedSegment(text.substring(cursor)));
    return out;
  }

  /// [text] with every span replaced by [dots].
  static String apply(String text, List<Span> spans) =>
      segments(text, spans).map((s) => s.text).join();

  /// Masks [values] wherever they occur in [text]. Used for titles, which are
  /// stored separately from the content. Values shorter than 3 characters are
  /// left alone; masking every "12" in a title would be noise.
  static String maskValues(String text, Iterable<String> values) {
    final sorted = values.where((v) => v.length >= 3).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var result = text;
    for (final value in sorted) {
      result = result.replaceAll(value, dots);
    }
    return result;
  }

  /// The masked text of a non-secret field that contains a secret, such as a
  /// database URL with its password: `postgres://app:••••••••@db/prod`.
  static String maskWithin(String content, Span range, List<Span> secretSpans) {
    final end = range.end.clamp(0, content.length);
    final start = range.start.clamp(0, end);
    final inside = <Span>[
      for (final s in secretSpans)
        if (s.overlaps(range)) Span(s.start - start, s.end - start),
    ];
    return apply(content.substring(start, end), inside);
  }

  /// What a hidden field chip shows: dots, or "•••• 4242" for a card number so
  /// you can still tell your cards apart.
  static String hiddenFieldText(ExtractedField field) {
    if (field.kind == FieldKind.card && field.value.length >= 4) {
      return '•••• ${field.value.substring(field.value.length - 4)}';
    }
    return dots;
  }
}
