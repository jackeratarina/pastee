import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../model/app_settings.dart';
import '../model/hotkey.dart';
import '../model/paste_item.dart';
import '../services/clipboard_service.dart';
import '../services/desktop_bridge.dart';
import '../services/field_extractor.dart';
import '../services/paste_titles.dart';
import '../services/storage_service.dart';

// ── services (overridden in main.dart and in tests) ───────────────────────

final pasteStoreProvider = Provider<PasteStore>((ref) => MemoryPasteStore());

final settingsStoreProvider =
    Provider<SettingsStore>((ref) => MemorySettingsStore());

final storageReportProvider =
    Provider<StorageReport>((ref) => const StorageReport());

final clipboardServiceProvider =
    Provider<ClipboardService>((ref) => const ClipboardService());

final desktopBridgeProvider =
    Provider<DesktopBridge>((ref) => MethodChannelDesktopBridge());

// ── settings ─────────────────────────────────────────────────────────────

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier(ref.watch(settingsStoreProvider));
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._store) : super(_load(_store));

  final SettingsStore _store;

  static const _kTheme = 'themeMode';
  static const _kHotKey = 'summonHotKey';
  static const _kHideAfterCopy = 'hideAfterCopy';
  static const _kMaskSecrets = 'maskSecrets';

  static AppSettings _load(SettingsStore store) {
    final theme = store.read(_kTheme);
    final hotKey = store.read(_kHotKey);
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == theme,
        orElse: () => ThemeMode.system,
      ),
      // Never set: use the recommended shortcut. 'off': the user turned it off.
      summonHotKey: hotKey == null
          ? defaultHotKey()
          : hotKey == 'off'
              ? null
              : HotKeySpec.fromJson(hotKey) ?? defaultHotKey(),
      hideAfterCopy: store.read(_kHideAfterCopy) as bool? ?? true,
      maskSecrets: store.read(_kMaskSecrets) as bool? ?? true,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _store.write(_kTheme, mode.name);
  }

  Future<void> setSummonHotKey(HotKeySpec? spec) async {
    state = state.copyWith(summonHotKey: () => spec);
    await _store.write(_kHotKey, spec?.toJson() ?? 'off');
  }

  Future<void> setHideAfterCopy(bool value) async {
    state = state.copyWith(hideAfterCopy: value);
    await _store.write(_kHideAfterCopy, value);
  }

  Future<void> setMaskSecrets(bool value) async {
    state = state.copyWith(maskSecrets: value);
    await _store.write(_kMaskSecrets, value);
  }
}

// ── global shortcut ──────────────────────────────────────────────────────

@immutable
class HotKeyStatus {
  const HotKeyStatus(
      {this.spec, this.active = false, this.error, this.supported = true});

  /// The shortcut Pastee tried to set, or null when it's off.
  final HotKeySpec? spec;
  final bool active;
  final String? error;
  final bool supported;
}

final hotKeyProvider =
    StateNotifierProvider<HotKeyNotifier, HotKeyStatus>((ref) {
  final notifier = HotKeyNotifier(ref.watch(desktopBridgeProvider));
  ref.listen<HotKeySpec?>(
    settingsProvider.select((s) => s.summonHotKey),
    (_, spec) => notifier.apply(spec),
    fireImmediately: true,
  );
  return notifier;
});

class HotKeyNotifier extends StateNotifier<HotKeyStatus> {
  HotKeyNotifier(this._bridge)
      : super(HotKeyStatus(supported: _bridge.isSupported));

  final DesktopBridge _bridge;
  HotKeySpec? _spec;

  Future<void> apply(HotKeySpec? spec) async {
    _spec = spec;
    if (!_bridge.isSupported) {
      state = HotKeyStatus(spec: spec, supported: false);
      return;
    }
    if (spec == null) {
      await _bridge.unregisterHotKey();
      if (mounted) state = const HotKeyStatus();
      return;
    }
    final result = await _bridge.registerHotKey(spec);
    if (!mounted || _spec != spec) return;
    state = HotKeyStatus(spec: spec, active: result.ok, error: result.error);
  }

  /// Releases the shortcut while the user records a new one, so pressing the
  /// current combination doesn't hide the window mid-recording.
  Future<void> pause() => _bridge.unregisterHotKey();

  Future<void> resume() => apply(_spec);
}

/// True while Pastee is showing because the summon shortcut brought it up.
/// Copying then hides it again (if that setting is on), and Escape hides it.
final summonedProvider = StateProvider<bool>((ref) => false);

// ── pastes ───────────────────────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((ref) => '');

final pasteListProvider =
    StateNotifierProvider<PasteListNotifier, List<PasteItem>>((ref) {
  return PasteListNotifier(ref.watch(pasteStoreProvider));
});

final filteredPasteListProvider = Provider<List<PasteItem>>((ref) {
  final items = ref.watch(pasteListProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase().trim();
  if (query.isEmpty) return items;

  return items.where((item) {
    return item.title.toLowerCase().contains(query) ||
        item.content.toLowerCase().contains(query);
  }).toList()
    ..sort((a, b) {
      final aTitle = a.title.toLowerCase().contains(query);
      final bTitle = b.title.toLowerCase().contains(query);
      if (aTitle && !bTitle) return -1;
      if (!aTitle && bTitle) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
});

class PasteListNotifier extends StateNotifier<List<PasteItem>> {
  PasteListNotifier(this._store) : super(_store.getAll());

  final PasteStore _store;
  static const _uuid = Uuid();
  static const _maxUndo = 20;

  /// Recently deleted items, newest last, for undo. Cleared by [clearAll].
  final List<PasteItem> _deleted = [];

  /// Contents being saved right now, so a quick double paste can't add the
  /// same text twice while the first write is still in flight.
  final Set<String> _adding = {};

  PasteItem? findByContent(String text) {
    for (final item in state) {
      if (item.content == text) return item;
    }
    return null;
  }

  /// Saves [text] as a new item, or returns null if it's already in the list.
  ///
  /// Text that is exactly a secret from another item (you copied a password
  /// from Pastee and pasted it back) is saved as an "always hide" item, since
  /// on its own it may not look like a password.
  Future<PasteItem?> addFromClipboard(String text) async {
    if (findByContent(text) != null || !_adding.add(text)) return null;
    try {
      final item = PasteItem(
        id: _uuid.v4(),
        title: autoTitle(text),
        content: text,
        createdAt: DateTime.now(),
        sensitive: _isKnownSecret(text),
      );
      // Disk first: if the write fails, the list doesn't show an item that
      // would be gone after a restart.
      await _store.put(item);
      state = [item, ...state];
      return item;
    } finally {
      _adding.remove(text);
    }
  }

  bool _isKnownSecret(String text) {
    final value = text.trim();
    if (value.isEmpty) return false;
    for (final item in state) {
      if (FieldExtractor.extract(item.content).secretValues.contains(value)) {
        return true;
      }
    }
    return false;
  }

  Future<void> updateTitle(String id, String newTitle) =>
      _update(id, (item) => item.copyWith(title: newTitle));

  Future<void> setSensitive(String id, bool sensitive) =>
      _update(id, (item) => item.copyWith(sensitive: sensitive));

  Future<void> _update(String id, PasteItem Function(PasteItem) change) async {
    final current = state.where((item) => item.id == id).firstOrNull;
    if (current == null) return;
    final updated = change(current);
    await _store.put(updated);
    state = [
      for (final item in state) item.id == id ? updated : item,
    ];
  }

  /// Removes the item. It can be brought back with [undoDelete].
  Future<PasteItem?> deleteItem(String id) async {
    final removed = state.where((item) => item.id == id).firstOrNull;
    if (removed == null) return null;
    await _store.delete(id);
    state = state.where((item) => item.id != id).toList();
    _deleted.add(removed);
    if (_deleted.length > _maxUndo) _deleted.removeAt(0);
    return removed;
  }

  bool get canUndo => _deleted.isNotEmpty;

  /// Puts the most recently deleted item back where it was (the list is
  /// ordered by date). Returns it, or null if there is nothing to undo.
  Future<PasteItem?> undoDelete() async {
    if (_deleted.isEmpty) return null;
    final item = _deleted.removeLast();
    if (state.any((existing) => existing.id == item.id)) return item;
    await _store.put(item);
    state = [...state, item]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return item;
  }

  /// Deletes everything. This can't be undone, so the undo history goes too.
  Future<void> clearAll() async {
    _deleted.clear();
    await _store.clear();
    state = [];
  }
}
