import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../model/paste_item.dart';
import 'file_permissions.dart';
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

  // Hive only ever appends to the file: deleting an item adds a "deleted"
  // marker and editing one adds a new copy, while the old record stays on disk
  // (encrypted) until the file is compacted, which Hive by itself does only
  // after 60 deletions. Compacting right away means a deleted or edited
  // password really is gone from the disk.

  @override
  Future<void> put(PasteItem item) async {
    final replacing = _box.containsKey(item.id);
    await _box.put(item.id, item);
    if (replacing) await _box.compact();
  }

  @override
  Future<void> delete(String id) async {
    await _box.delete(id);
    await _box.compact();
  }

  @override
  Future<void> clear() async {
    await _box.clear();
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
    this.unreadableKeyBackup,
  });

  final String? dataPath;
  final bool encrypted;

  /// Items moved over from Pastee 1.0's unencrypted file in Documents.
  final int migratedCount;

  /// Saved items that could not be decrypted (their key was lost) are moved
  /// here instead of being deleted.
  final String? unreadableBackup;

  /// A key file that could not be read is kept here, so the items above can
  /// still be recovered if it becomes readable again.
  final String? unreadableKeyBackup;
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

  /// Opens storage in the platform's application-support folder:
  /// `~/Library/Application Support/com.pastee.pastee/data` on macOS,
  /// `%APPDATA%\\com.pastee\\Pastee\\data` on Windows,
  /// `~/.local/share/com.pastee.pastee/data` on Linux.
  static Future<OpenedStorage> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final dataDir = Directory(p.join(support.path, 'data'));
    return open(
      dataDir: dataDir,
      legacyDir: await _legacyDir(),
      keyStore: FileKeyStore(
        File(p.join(dataDir.path, 'key.bin')),
        protector: Platform.isWindows
            ? DpapiKeyProtector()
            : const PlainKeyProtector(),
      ),
    );
  }

  /// The Documents folder Pastee 1.0 saw, where it kept its unencrypted box.
  ///
  /// On Windows that is the user's Documents. Pastee 1.0 ran sandboxed on
  /// macOS, so there it is Documents inside the old app container. (Pastee 1.1
  /// isn't sandboxed, and looking in the real ~/Documents would make macOS
  /// show every user a privacy prompt.)
  static Future<Directory?> _legacyDir() async {
    try {
      if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home == null) return null;
        return Directory(p.join(home, 'Library', 'Containers',
            'com.pastee.pastee', 'Data', 'Documents'));
      }
      if (Platform.isWindows) return await getApplicationDocumentsDirectory();
    } catch (_) {
      // No legacy folder to look at.
    }
    return null;
  }

  static Future<OpenedStorage> open({
    required Directory dataDir,
    required FileKeyStore keyStore,
    Directory? legacyDir,
  }) async {
    await dataDir.create(recursive: true);
    restrictToOwner(dataDir.path, directory: true);
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
    int? stored;
    File? safetyCopy;
    var sizeBefore = 0;
    if (await boxFile.exists()) {
      stored = await crcFile.exists()
          ? int.tryParse((await crcFile.readAsString()).trim())
          : null;
      if (stored == null) {
        // Fingerprint missing or torn (crash while it was written): the key
        // may well be right. Keep a copy in case Hive "recovers" the file.
        sizeBefore = await boxFile.length();
        safetyCopy = await boxFile.copy(_asideName(boxFile));
      } else if (stored != keyCrc) {
        unreadableBackup = await _moveAside(boxFile);
      }
    }

    final box =
        await Hive.openBox<PasteItem>(pastesBox, encryptionCipher: cipher);
    if (safetyCopy != null) {
      if (await boxFile.length() < sizeBefore && box.isEmpty) {
        unreadableBackup = safetyCopy.path; // the key really was wrong
      } else {
        await safetyCopy.delete();
      }
    }
    if (stored != keyCrc) {
      // Only when it changed, and atomically: a torn fingerprint file must
      // never make good data look unreadable.
      final tmp = File('${crcFile.path}.tmp');
      await tmp.writeAsString('$keyCrc', flush: true);
      await tmp.rename(crcFile.path);
    }

    var migrated = 0;
    if (legacyDir != null) migrated = await _migrateLegacy(box, legacyDir);

    // Pastee 1.1.0 didn't compact after deleting or editing, so its file can
    // still hold old records. This does nothing when there are none.
    await box.compact();

    final settings = await Hive.openBox<dynamic>(settingsBox);
    return OpenedStorage(
      HivePasteStore(box),
      HiveSettingsStore(settings),
      StorageReport(
        dataPath: dataDir.path,
        encrypted: true,
        migratedCount: migrated,
        unreadableBackup: unreadableBackup,
        unreadableKeyBackup: key.unreadableBackup,
      ),
    );
  }

  static String _asideName(File boxFile) {
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    return p.join(boxFile.parent.path, '$pastesBox-unreadable-$stamp.hive');
  }

  static Future<String> _moveAside(File boxFile) async {
    final target = _asideName(boxFile);
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
