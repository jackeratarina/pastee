import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/field_config.dart';
import '../services/field_extractor.dart';
import '../services/pattern_guard.dart';
import '../services/storage_service.dart';
import 'providers.dart';

/// Your own fields and the numbers fields get (Settings → Fields & numbers).
/// Everything that finds fields reads this, so tiles, masking, titles and
/// ⌘1–9 always agree.
final fieldConfigProvider =
    StateNotifierProvider<FieldConfigNotifier, FieldConfig>((ref) {
  return FieldConfigNotifier(ref.watch(settingsStoreProvider));
});

/// The fields in [content] with the current settings.
Extraction extractFields(WidgetRef ref, String content) =>
    FieldExtractor.extract(content, config: ref.read(fieldConfigProvider));

/// Times a value pattern on hard text before it is saved (after
/// [PatternGuard.quickCheck] passed); returns what's wrong, or null. Tests
/// replace it, since the real one runs a background isolate.
final patternSpeedCheckProvider =
    Provider<Future<String?> Function(String pattern)>(
        (ref) => PatternGuard.checkSpeed);

class FieldConfigNotifier extends StateNotifier<FieldConfig> {
  FieldConfigNotifier(this._store)
      : super(FieldConfig.decode(_store.read(storageKey)));

  /// One key holds it all, as JSON.
  static const storageKey = 'fields';

  final SettingsStore _store;

  Future<void> set(FieldConfig config) async {
    if (config == state) return;
    state = config;
    await _store.write(storageKey, config.isDefault ? null : config.encode());
  }

  /// Adds [rule], or replaces the rule with the same id.
  Future<void> saveRule(CustomFieldRule rule) => set(state.withRule(rule));

  Future<void> removeRule(String id) => set(state.withoutRule(id));

  Future<void> setRuleEnabled(String id, bool enabled) {
    final rule = state.custom.where((r) => r.id == id).firstOrNull;
    if (rule == null) return Future.value();
    return saveRule(rule.copyWith(enabled: enabled));
  }

  Future<void> setBuiltIn(BuiltInField field, BuiltInFieldSetting setting) =>
      set(state.withBuiltIn(field, setting));

  Future<void> setNumberLines(bool value) =>
      set(state.copyWith(numberLines: value));

  Future<void> reset() => set(FieldConfig.defaults);
}
