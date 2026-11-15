import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/services/key_store.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/services/text_utils.dart';

void main() {
  late Directory root;
  late Directory dataDir;
  late Directory legacyDir;

  FileKeyStore keyStore() =>
      FileKeyStore(File(p.join(dataDir.path, 'key.bin')));

  PasteItem item(String id, String content, {String? title}) => PasteItem(
        id: id,
        title: title ?? content,
        content: content,
        createdAt: DateTime(2026, 1, 1).add(Duration(minutes: int.parse(id))),
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pastee_storage_test');
    dataDir = Directory(p.join(root.path, 'support', 'data'));
    legacyDir = Directory(p.join(root.path, 'Documents'))
      ..createSync(recursive: true);
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('items survive a restart and are encrypted on disk', () async {
    var storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    await storage.pastes.put(item('1', 'my bank password is Tr0ub4dor&3'));
    await storage.settings.write('maskSecrets', false);
    await Hive.close();

    final raw = await File(p.join(dataDir.path, 'pastes.hive')).readAsBytes();
    expect(
        utf8.decode(raw, allowMalformed: true), isNot(contains('Tr0ub4dor')));

    storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    expect(storage.pastes.getAll().single.content,
        'my bank password is Tr0ub4dor&3');
    expect(storage.settings.read('maskSecrets'), false);
    expect(storage.report.encrypted, isTrue);
    expect(storage.report.unreadableBackup, isNull);
  });

  test('deleting or editing an item leaves no old copy in the file', () async {
    final storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    final file = File(p.join(dataDir.path, 'pastes.hive'));
    await storage.pastes.put(item('1', 'password: Tr0ub4dor&3'));
    final oneRecord = await file.length();

    // Hive appends the new version; compaction drops the old one.
    await storage.pastes.put(item('1', 'password: Tr0ub4dor&4'));
    expect(await file.length(), oneRecord);

    await storage.pastes.delete('1');
    expect(await file.length(), 0);
    expect(storage.pastes.getAll(), isEmpty);
  });

  test('opening the store removes what 1.1.0 left behind after deleting',
      () async {
    var storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    await storage.pastes.put(item('1', 'keep me'));
    final file = File(p.join(dataDir.path, 'pastes.hive'));
    final oneRecord = await file.length();
    // What 1.1.0 did: delete without compacting.
    final box = Hive.box<PasteItem>(Storage.pastesBox);
    await box.put('2', item('2', 'password: Tr0ub4dor&3'));
    await box.delete('2');
    await Hive.close();
    expect(await file.length(), greaterThan(oneRecord));

    storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    expect(storage.pastes.getAll().single.content, 'keep me');
    expect(await file.length(), oneRecord);
  });

  test('a lost key never wipes the old file: it is moved aside', () async {
    var storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    await storage.pastes.put(item('1', 'precious'));
    await Hive.close();
    final before =
        await File(p.join(dataDir.path, 'pastes.hive')).readAsBytes();

    await File(p.join(dataDir.path, 'key.bin')).delete();
    storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());

    expect(storage.pastes.getAll(), isEmpty);
    final backup = storage.report.unreadableBackup;
    expect(backup, isNotNull);
    expect(await File(backup!).readAsBytes(), before);
  });

  test(
      'Pastee 1.0 data in Documents is migrated and the plaintext file removed',
      () async {
    // Write a 1.0-style box: unencrypted, named paste_items, in Documents.
    Hive.init(legacyDir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(PasteItemAdapter());
    final legacy = await Hive.openBox<PasteItem>('paste_items');
    const wifi = 'password: hunter2!\nfor the wifi';
    await legacy.put('1', item('1', wifi, title: legacyAutoTitle(wifi)));
    await legacy.put('2', item('2', 'groceries', title: 'My list'));
    await Hive.close();

    final storage = await Storage.open(
        dataDir: dataDir, keyStore: keyStore(), legacyDir: legacyDir);

    expect(storage.report.migratedCount, 2);
    expect(
        File(p.join(legacyDir.path, 'paste_items.hive')).existsSync(), isFalse);
    final items = {for (final i in storage.pastes.getAll()) i.id: i};
    expect(items['1']!.content, 'password: hunter2!\nfor the wifi');
    expect(items['1']!.title, 'password: ••••••••',
        reason: '1.0 titles could show the password');
    expect(items['2']!.title, 'My list',
        reason: 'titles the user typed are kept');

    // Running again (say the delete had failed) doesn't duplicate anything.
    await Hive.close();
    final again = await Storage.open(
        dataDir: dataDir, keyStore: keyStore(), legacyDir: legacyDir);
    expect(again.pastes.getAll(), hasLength(2));
    expect(again.report.migratedCount, 0);
  });

  test('1.0 titles with half an emoji are repaired', () {
    final content = '${'x' * 29}🎂 party';
    final broken = content.substring(0, 30); // ends in a lone surrogate
    final upgraded =
        Storage.upgradeLegacyItem(item('1', content, title: '$broken edited'));
    expect(upgraded.title, contains('�'));
    expect(upgraded.title.codeUnits.where((u) => u >= 0xD800 && u <= 0xDFFF),
        isEmpty);
  });

  test('older records without the sensitive flag still load', () async {
    final storage = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    final restored = item('1', 'x').copyWith(sensitive: true);
    await storage.pastes.put(restored);
    expect(storage.pastes.getAll().single.sensitive, isTrue);
  });

  group('FileKeyStore', () {
    test('creates a 32-byte key once and reuses it', () async {
      final first = await keyStore().loadOrCreate();
      final second = await keyStore().loadOrCreate();
      expect(first.created, isTrue);
      expect(second.created, isFalse);
      expect(first.bytes, hasLength(32));
      expect(second.bytes, first.bytes);
    });

    test('an unreadable key file is kept aside and replaced', () async {
      final file = File(p.join(dataDir.path, 'key.bin'));
      await file.create(recursive: true);
      await file.writeAsString('garbage');
      final loaded = await keyStore().loadOrCreate();
      expect(loaded.created, isTrue);
      expect(loaded.unreadableBackup, isNotNull);
      expect(File(loaded.unreadableBackup!).readAsStringSync(), 'garbage');
    });

    test('Windows DPAPI round-trips and binds the key to this user', () async {
      final protector = DpapiKeyProtector();
      final secret = utf8.encode('0123456789abcdef0123456789abcdef');
      final wrapped = protector.protect(secret);
      expect(wrapped, isNot(secret));
      expect(protector.unprotect(wrapped), secret);

      final store = FileKeyStore(File(p.join(dataDir.path, 'key.bin')),
          protector: protector);
      final created = await store.loadOrCreate();
      final loaded = await store.loadOrCreate();
      expect(loaded.created, isFalse);
      expect(loaded.bytes, created.bytes);
    }, skip: !Platform.isWindows ? 'DPAPI only exists on Windows' : false);
  });
}
