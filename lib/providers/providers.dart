import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/services/clipboard_service.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:uuid/uuid.dart';

final storageServiceProvider = Provider<StorageService>((ref) {
  return StorageService();
});

final clipboardServiceProvider = Provider<ClipboardService>((ref) {
  return ClipboardService();
});

final themeProvider = StateNotifierProvider<ThemeNotifier, bool>((ref) {
  return ThemeNotifier();
});

class ThemeNotifier extends StateNotifier<bool> {
  ThemeNotifier() : super(false);

  void toggle() => state = !state;
}

final searchQueryProvider = StateProvider<String>((ref) => '');

final pasteListProvider =
    StateNotifierProvider<PasteListNotifier, List<PasteItem>>((ref) {
  final storage = ref.watch(storageServiceProvider);
  return PasteListNotifier(storage);
});

final filteredPasteListProvider = Provider<List<PasteItem>>((ref) {
  final items = ref.watch(pasteListProvider);
  final query = ref.watch(searchQueryProvider).toLowerCase().trim();
  if (query.isEmpty) return items;

  return items.where((item) {
    final titleMatch = item.title.toLowerCase().contains(query);
    final contentMatch = item.content.toLowerCase().contains(query);
    return titleMatch || contentMatch;
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
  final StorageService _storage;
  static const _uuid = Uuid();

  PasteListNotifier(this._storage) : super([]) {
    _load();
  }

  void _load() {
    state = _storage.getAll();
  }

  bool containsContent(String text) {
    return state.any((item) => item.content == text);
  }

  Future<void> addFromClipboard(String text) async {
    if (containsContent(text)) return;

    final title = text.length > 30 ? text.substring(0, 30) : text;
    final item = PasteItem(
      id: _uuid.v4(),
      title: title.replaceAll('\n', ' ').trim(),
      content: text,
      createdAt: DateTime.now(),
    );
    await _storage.add(item);
    state = [item, ...state];
  }

  Future<void> updateTitle(String id, String newTitle) async {
    final index = state.indexWhere((item) => item.id == id);
    if (index == -1) return;

    final updated = state[index].copyWith(title: newTitle);
    state = [
      ...state.sublist(0, index),
      updated,
      ...state.sublist(index + 1),
    ];
    await _storage.update(updated);
  }

  Future<void> deleteItem(String id) async {
    await _storage.delete(id);
    state = state.where((item) => item.id != id).toList();
  }

  Future<void> clearAll() async {
    await _storage.clear();
    state = [];
  }
}
