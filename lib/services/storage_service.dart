import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/paste_item.dart';
import 'key_store.dart';
import 'paste_titles.dart';
import 'text_utils.dart';

/// Where pastes are kept. Swapped for [MemoryPasteStore] in tests.
abstract class PasteStore {
  List<PasteItem> getAll();
  Future<void> put(PasteItem item);
  Future<void> delete(String id);
  Future<void> clear();
}

/// Small key–value store for preferences.
abstract class SettingsStore {
  Object? read(String key);
  Future<void> write(String key, Object? value);
}

class MemoryPasteStore implements PasteStore {
  MemoryPasteStore([Iterable<PasteItem> items = const []]) {
    for (final item in items) {
      _items[item.id] = item;
    }
  }

  final Map<String, PasteItem> _items = {};

  @override
  List<PasteItem> getAll() => _items.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> put(PasteItem item) async => _items[item.id] = item;

  @override
  Future<void> delete(String id) async => _items.remove(id);

  @override
  Future<void> clear() async => _items.clear();
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([Map<String, Object?>? values]) : values = {...?values};

  final Map<String, Object?> values;

  @override
  Object? read(String key) => values[key];

  @override
  Future<void> write(String key, Object? value) async => values[key] = value;
}

class HivePasteStore implements PasteStore {
  HivePasteStore(this._box);

  final Box<PasteItem> _box;

  @override
  List<PasteItem> getAll() =>
      _box.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> put(PasteItem item) => _box.put(item.id, item);

  @override
  Future<void> delete(String id) => _box.delete(id);

  @override
  Future<void> clear() async {
    await _box.clear();
    // Drop the old (encrypted) records from the file right away.
    await _box.compact();
  }
}

class HiveSettingsStore implements SettingsStore {
  HiveSettingsStore(this._box);

  final Box<dynamic> _box;

  @override
  Object? read(String key) => _box.get(key);

  @override
  Future<void> write(String key, Object? value) =>
      value == null ? _box.delete(key) : _box.put(key, value);
}

/// What happened while opening storage, shown to the user when it matters.
@immutable
class StorageReport {
  const StorageReport({
    this.dataPath,
    this.encrypted = false,
    this.migratedCount = 0,
    this.unreadableBackup,
  });

  final String? dataPath;
  final bool encrypted;

  /// Items moved over from Pastee 1.0's unencrypted file in Documents.
  final int migratedCount;

  /// Saved items that could not be decrypted (their key was lost) are moved
  /// here instead of being deleted.
  final String? unreadableBackup;
}

class OpenedStorage {
  const OpenedStorage(this.pastes, this.settings, this.report);

  final PasteStore pastes;
  final SettingsStore settings;
  final StorageReport report;
}

class Storage {
  Storage._();

  static const pastesBox = 'pastes';
  static const settingsBox = 'settings';

  /// Pastee 1.0 kept an unencrypted box with this name in Documents (which
  /// OneDrive syncs on many Windows PCs).
  static const legacyBox = 'paste_items';

  /// Opens storage in the platform's application-support folder.
  static Future<OpenedStorage> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final dataDir = Directory(p.join(support.path, 'data'));
    Directory? legacyDir;
    try {
      legacyDir = await getApplicationDocumentsDirectory();
    } catch (_) {
      legacyDir = null;
    }
    return open(
      dataDir: dataDir,
      legacyDir: legacyDir,
      keyStore: FileKeyStore(
        File(p.join(dataDir.path, 'key.bin')),
        protector: Platform.isWindows
            ? DpapiKeyProtector()
            : const PlainKeyProtector(),
      ),
    );
  }

  static Future<OpenedStorage> open({
    required Directory dataDir,
    required FileKeyStore keyStore,
    Directory? legacyDir,
  }) async {
    await dataDir.create(recursive: true);
    Hive.init(dataDir.path);
    if (!Hive.isAdapterRegistered(PasteItemAdapter().typeId)) {
      Hive.registerAdapter(PasteItemAdapter());
    }

    final key = await keyStore.loadOrCreate();
    final cipher = HiveAesCipher(key.bytes);
    final keyCrc = cipher.calculateKeyCrc();
    final boxFile = File(p.join(dataDir.path, '$pastesBox.hive'));
    final crcFile = File(p.join(dataDir.path, '$pastesBox.keycrc'));

    // Opening a Hive box with the wrong key makes Hive "recover" it by
    // truncating the file to nothing. So check the key first, and if it
    // doesn't match, move the file aside instead of letting Hive wipe it.
    String? unreadableBackup;
    if (await boxFile.exists()) {
      final stored = await crcFile.exists()
          ? int.tryParse((await crcFile.readAsString()).trim())
          : null;
      if (stored != keyCrc) unreadableBackup = await _moveAside(boxFile);
    }

    final box =
        await Hive.openBox<PasteItem>(pastesBox, encryptionCipher: cipher);
    await crcFile.writeAsString('$keyCrc', flush: true);

    var migrated = 0;
    if (legacyDir != null) migrated = await _migrateLegacy(box, legacyDir);

    final settings = await Hive.openBox<dynamic>(settingsBox);
    return OpenedStorage(
      HivePasteStore(box),
      HiveSettingsStore(settings),
      StorageReport(
        dataPath: dataDir.path,
        encrypted: true,
        migratedCount: migrated,
        unreadableBackup: unreadableBackup,
      ),
    );
  }

  static Future<String> _moveAside(File boxFile) async {
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final target =
        p.join(boxFile.parent.path, '$pastesBox-unreadable-$stamp.hive');
    await boxFile.rename(target);
    final lock = File(p.setExtension(boxFile.path, '.lock'));
    if (await lock.exists()) await lock.delete();
    return target;
  }

  /// Copies items from Pastee 1.0's plaintext box into [box], then deletes the
  /// old file. Items that already exist are left alone, so a migration that was
  /// interrupted can safely run again.
  static Future<int> _migrateLegacy(
      Box<PasteItem> box, Directory legacyDir) async {
    final legacyFile = File(p.join(legacyDir.path, '$legacyBox.hive'));
    if (!await legacyFile.exists()) return 0;
    try {
      final legacy =
          await Hive.openBox<PasteItem>(legacyBox, path: legacyDir.path);
      var copied = 0;
      for (final item in legacy.values) {
        if (box.containsKey(item.id)) continue;
        await box.put(item.id, upgradeLegacyItem(item));
        copied++;
      }
      await box.flush();
      await legacy.deleteFromDisk();
      return copied;
    } catch (error) {
      debugPrint('Pastee: could not migrate $legacyFile: $error');
      return 0;
    }
  }

  /// 1.0 titles were the first 30 UTF-16 units of the content: they could show
  /// a password and could end in half an emoji. Regenerate those; keep titles
  /// the user typed (but make them drawable).
  @visibleForTesting
  static PasteItem upgradeLegacyItem(PasteItem item) {
    if (item.title == legacyAutoTitle(item.content)) {
      return item.copyWith(title: autoTitle(item.content));
    }
    return item.copyWith(title: sanitizeUtf16(item.title));
  }
}
