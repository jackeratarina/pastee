import 'package:pastee/model/field_config.dart';
import 'package:pastee/services/field_extractor.dart';

/// One of "Your phrases", with its name as its id.
CustomFieldRule rule(
  String name, {
  List<String> phrases = const [],
  String pattern = '',
  bool secret = false,
  int? number,
  bool enabled = true,
}) =>
    CustomFieldRule(
      id: 'id-$name',
      name: name,
      phrases: phrases,
      pattern: pattern,
      secret: secret,
      number: number,
      enabled: enabled,
    );

FieldConfig configWith(
  List<CustomFieldRule> rules, {
  Map<BuiltInField, BuiltInFieldSetting> builtIn = const {},
  bool numberLines = true,
}) =>
    FieldConfig(custom: rules, builtIn: builtIn, numberLines: numberLines);

Extraction run(String text, FieldConfig config) =>
    FieldExtractor.extract(text, config: config);

ExtractedField? customField(Extraction extraction, String name) {
  for (final field in extraction.fields) {
    if (field.kind == FieldKind.custom && field.label == name) return field;
  }
  return null;
}

/// Name → value of the first field each of your rules found in [text].
Map<String, String> valuesOf(String text, FieldConfig config) => {
      for (final field in run(text, config).fields.reversed)
        if (field.kind == FieldKind.custom) field.label: field.value,
    };

/// Whether every occurrence of [value] in [text] is masked.
bool isMaskedEverywhere(Extraction extraction, String text, String value) {
  var from = 0;
  var found = false;
  while (true) {
    final at = text.indexOf(value, from);
    if (at < 0) return found;
    found = true;
    final covered = extraction.secretSpans
        .any((s) => s.start <= at && at + value.length <= s.end);
    if (!covered) return false;
    from = at + 1;
  }
}

/// (number, value) of every field, in order.
List<(int, String)> numbered(Extraction extraction) =>
    [for (final f in extraction.fields) (f.number, f.value)];
