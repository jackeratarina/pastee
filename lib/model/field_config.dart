/// Which fields Pastee numbers and how (Settings → Fields & numbers): your own
/// phrases, the built-in kinds you turned off or gave a number, and whether
/// plain lines are numbered too.
///
/// Pure Dart, no Flutter imports, so the field extractor can use it.
library;

import 'dart:convert';

/// The built-in kinds of field, grouped the way Settings shows them.
///
/// The names are saved in settings: never rename one.
enum BuiltInField {
  password,
  pin,
  card,
  token,
  username,
  email,
  link,
  ip,
  phone,
  reference,
  labeled;

  /// Secret kinds are masked whether or not they are fields: turning one off
  /// only removes its chip and number.
  bool get secret => switch (this) {
        password || pin || card || token => true,
        _ => false,
      };

  static BuiltInField? byName(Object? name) {
    for (final field in values) {
      if (field.name == name) return field;
    }
    return null;
  }
}

/// The numbers a field can have: ⌘1–⌘9 (Ctrl+1–9 on Windows).
const int minFieldNumber = 1;
const int maxFieldNumber = 9;

/// [number] if it is a field number, otherwise null (Auto).
int? validFieldNumber(Object? number) =>
    number is int && number >= minFieldNumber && number <= maxFieldNumber
        ? number
        : null;

/// How one built-in kind is treated.
final class BuiltInFieldSetting {
  const BuiltInFieldSetting({this.enabled = true, this.number});

  static const standard = BuiltInFieldSetting();

  /// Off: the kind gets no chip and no number. Its text is still not offered
  /// as a plain line, and secrets are still masked.
  final bool enabled;

  /// The number this kind asks for, or null for Auto.
  final int? number;

  bool get isStandard => enabled && number == null;

  BuiltInFieldSetting copyWith({bool? enabled, int? Function()? number}) =>
      BuiltInFieldSetting(
        enabled: enabled ?? this.enabled,
        number: number != null ? validFieldNumber(number()) : this.number,
      );

  Map<String, Object?> toJson() => {'enabled': enabled, 'number': number};

  static BuiltInFieldSetting? fromJson(Object? json) {
    if (json is! Map) return null;
    final enabled = json['enabled'];
    return BuiltInFieldSetting(
      enabled: enabled is bool ? enabled : true,
      number: validFieldNumber(json['number']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BuiltInFieldSetting &&
      other.enabled == enabled &&
      other.number == number;

  @override
  int get hashCode => Object.hash(enabled, number);

  @override
  String toString() =>
      'BuiltInFieldSetting(enabled: $enabled, number: $number)';
}

/// One of "Your phrases": a value Pastee picks out because you said so.
///
/// It is found after one of its [phrases] ("Member ID: 12345"), or wherever
/// its [pattern] matches when it has no phrases.
final class CustomFieldRule {
  CustomFieldRule({
    required this.id,
    required String name,
    Iterable<String> phrases = const [],
    String pattern = '',
    this.secret = false,
    int? number,
    this.enabled = true,
  })  : name = name.trim(),
        phrases = List.unmodifiable(cleanPhrases(phrases)),
        pattern = pattern.trim().isEmpty ? '' : pattern,
        number = validFieldNumber(number);

  static const int maxPhrases = 20;
  static const int maxPhraseLength = 100;
  static const int maxNameLength = 40;

  /// Stable identity, for editing and list keys.
  final String id;

  /// Shown on the chip and in the "Copied …" message.
  final String name;

  /// Labels that come before the value. Matched ignoring case, accents and
  /// extra spaces.
  final List<String> phrases;

  /// A regular expression the value must match, or '' for none.
  final String pattern;

  /// Masked like a password, and treated as a secret when copied.
  final bool secret;

  /// The number this field asks for, or null for Auto.
  final int? number;

  final bool enabled;

  bool get hasPattern => pattern.isNotEmpty;

  /// Trimmed, non-empty, without duplicates, and within the limits.
  static List<String> cleanPhrases(Iterable<String> phrases) {
    final seen = <String>{};
    return [
      for (final phrase in phrases.map((p) => p.trim()))
        if (phrase.isNotEmpty &&
            phrase.length <= maxPhraseLength &&
            !phrase.contains('\n') &&
            seen.add(phrase))
          phrase,
    ].take(maxPhrases).toList();
  }

  CustomFieldRule copyWith({
    String? name,
    Iterable<String>? phrases,
    String? pattern,
    bool? secret,
    int? Function()? number,
    bool? enabled,
  }) =>
      CustomFieldRule(
        id: id,
        name: name ?? this.name,
        phrases: phrases ?? this.phrases,
        pattern: pattern ?? this.pattern,
        secret: secret ?? this.secret,
        number: number != null ? number() : this.number,
        enabled: enabled ?? this.enabled,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'phrases': phrases,
        'pattern': pattern,
        'secret': secret,
        'number': number,
        'enabled': enabled,
      };

  /// Null if [json] is not a usable rule: no name, or nothing to look for.
  static CustomFieldRule? fromJson(Object? json, {required String fallbackId}) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final phrases = json['phrases'];
    final pattern = json['pattern'];
    final secret = json['secret'];
    final enabled = json['enabled'];
    if (name is! String || name.trim().isEmpty) return null;
    final rule = CustomFieldRule(
      id: id is String && id.isNotEmpty ? id : fallbackId,
      name: name,
      phrases: phrases is List ? phrases.whereType<String>() : const [],
      pattern: pattern is String ? pattern : '',
      secret: secret is bool && secret,
      number: validFieldNumber(json['number']),
      enabled: enabled is bool ? enabled : true,
    );
    return rule.phrases.isEmpty && !rule.hasPattern ? null : rule;
  }

  @override
  bool operator ==(Object other) =>
      other is CustomFieldRule &&
      other.id == id &&
      other.name == name &&
      _listEquals(other.phrases, phrases) &&
      other.pattern == pattern &&
      other.secret == secret &&
      other.number == number &&
      other.enabled == enabled;

  @override
  late final int hashCode = Object.hash(
      id, name, Object.hashAll(phrases), pattern, secret, number, enabled);

  @override
  String toString() => 'CustomFieldRule($name, phrases: $phrases, '
      'pattern: "$pattern", secret: $secret, number: $number, '
      'enabled: $enabled)';
}

/// Everything on the Fields & numbers page.
final class FieldConfig {
  FieldConfig({
    Iterable<CustomFieldRule> custom = const [],
    Map<BuiltInField, BuiltInFieldSetting> builtIn = const {},
    this.numberLines = true,
  })  : custom = List.unmodifiable(custom),
        builtIn = Map.unmodifiable({
          for (final entry in builtIn.entries)
            if (!entry.value.isStandard) entry.key: entry.value,
        });

  /// What Pastee does when nothing was changed: no phrases of your own, every
  /// built-in kind on and numbered automatically, plain lines numbered too.
  static final FieldConfig defaults = FieldConfig();

  static const int version = 1;
  static const int maxRules = 50;

  /// Your phrases, in the order they are listed.
  final List<CustomFieldRule> custom;

  /// Only kinds that differ from [BuiltInFieldSetting.standard].
  final Map<BuiltInField, BuiltInFieldSetting> builtIn;

  /// Number plain lines after the detected fields.
  final bool numberLines;

  BuiltInFieldSetting operator [](BuiltInField field) =>
      builtIn[field] ?? BuiltInFieldSetting.standard;

  bool get isDefault => custom.isEmpty && builtIn.isEmpty && numberLines;

  /// The rules that can find something.
  Iterable<CustomFieldRule> get activeRules => custom.where(
      (rule) => rule.enabled && (rule.phrases.isNotEmpty || rule.hasPattern));

  FieldConfig copyWith({
    Iterable<CustomFieldRule>? custom,
    Map<BuiltInField, BuiltInFieldSetting>? builtIn,
    bool? numberLines,
  }) =>
      FieldConfig(
        custom: custom ?? this.custom,
        builtIn: builtIn ?? this.builtIn,
        numberLines: numberLines ?? this.numberLines,
      );

  /// Replaces the rule with the same id, or adds [rule] at the end.
  FieldConfig withRule(CustomFieldRule rule) {
    final index = custom.indexWhere((r) => r.id == rule.id);
    if (index < 0) return copyWith(custom: [...custom, rule]);
    return copyWith(custom: [
      for (var i = 0; i < custom.length; i++) i == index ? rule : custom[i],
    ]);
  }

  FieldConfig withoutRule(String id) =>
      copyWith(custom: custom.where((r) => r.id != id));

  FieldConfig withBuiltIn(BuiltInField field, BuiltInFieldSetting setting) =>
      copyWith(builtIn: {...builtIn, field: setting});

  Map<String, Object?> toJson() => {
        'version': version,
        'custom': [for (final rule in custom) rule.toJson()],
        'builtIn': {
          for (final entry in builtIn.entries)
            entry.key.name: entry.value.toJson(),
        },
        'numberLines': numberLines,
      };

  /// What gets saved in settings.
  String encode() => jsonEncode(toJson());

  /// Reads what [encode] saved (or the decoded map). Missing, unknown or
  /// corrupt data gives [defaults]; a single bad rule or entry is skipped.
  static FieldConfig decode(Object? stored) {
    try {
      final json = stored is String ? jsonDecode(stored) : stored;
      if (json is! Map || json['version'] != version) return defaults;
      final custom = json['custom'];
      final builtIn = json['builtIn'];
      final numberLines = json['numberLines'];
      final rules = <CustomFieldRule>[];
      final ids = <String>{};
      if (custom is List) {
        for (final entry in custom) {
          if (rules.length >= maxRules) break;
          var rule = CustomFieldRule.fromJson(entry,
              fallbackId: 'rule-${rules.length + 1}');
          if (rule == null) continue;
          if (!ids.add(rule.id)) {
            // Two rules with one id can't be edited apart: give it a new one.
            var n = rules.length + 1;
            while (!ids.add('rule-$n')) {
              n++;
            }
            rule = CustomFieldRule(
              id: 'rule-$n',
              name: rule.name,
              phrases: rule.phrases,
              pattern: rule.pattern,
              secret: rule.secret,
              number: rule.number,
              enabled: rule.enabled,
            );
          }
          rules.add(rule);
        }
      }
      final settings = <BuiltInField, BuiltInFieldSetting>{};
      if (builtIn is Map) {
        for (final entry in builtIn.entries) {
          final field = BuiltInField.byName(entry.key);
          final setting = BuiltInFieldSetting.fromJson(entry.value);
          if (field != null && setting != null) settings[field] = setting;
        }
      }
      return FieldConfig(
        custom: rules,
        builtIn: settings,
        numberLines: numberLines is bool ? numberLines : true,
      );
    } catch (_) {
      return defaults;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FieldConfig ||
        other.hashCode != hashCode ||
        other.numberLines != numberLines ||
        !_listEquals(other.custom, custom) ||
        other.builtIn.length != builtIn.length) {
      return false;
    }
    for (final entry in builtIn.entries) {
      if (other.builtIn[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  late final int hashCode = Object.hash(
    Object.hashAll(custom),
    Object.hashAllUnordered(
        builtIn.entries.map((e) => Object.hash(e.key, e.value))),
    numberLines,
  );

  @override
  String toString() =>
      'FieldConfig(custom: $custom, builtIn: $builtIn, numberLines: $numberLines)';
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
