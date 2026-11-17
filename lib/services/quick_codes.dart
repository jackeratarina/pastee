import '../model/quick_code.dart';
import 'field_extractor.dart';

/// The index in [extraction] of the field [code] copies, or -1 when the note
/// no longer shows such a field.
///
/// That is the field at the code's place in the note or, when a Fields &
/// numbers change moved a field's edges, a field overlapping it.
int quickCodeFieldIndex(QuickCode code, Extraction extraction) {
  final fields = extraction.fields;
  var overlapping = -1;
  for (var i = 0; i < fields.length; i++) {
    final span = fields[i].span;
    if (code.hasSpan(span.start, span.end)) return i;
    if (overlapping < 0 && span.start < code.end && code.start < span.end) {
      overlapping = i;
    }
  }
  return overlapping;
}

/// The codes among [codes] that copy field [index] of [extraction], the one
/// set on exactly that field first. Usually none or one.
List<QuickCode> quickCodesOfField(
    List<QuickCode> codes, Extraction extraction, int index) {
  if (index < 0 || index >= extraction.fields.length) return const [];
  final span = extraction.fields[index].span;
  return [
    for (final code in codes)
      if (quickCodeFieldIndex(code, extraction) == index) code,
  ]..sort((a, b) => (b.hasSpan(span.start, span.end) ? 1 : 0)
      .compareTo(a.hasSpan(span.start, span.end) ? 1 : 0));
}
