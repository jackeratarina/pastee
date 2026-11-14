import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/services/key_store.dart';
import 'package:pastee/services/storage_service.dart';

void main() {
  late Directory root, dataDir;
  FileKeyStore keyStore() =>
      FileKeyStore(File(p.join(dataDir.path, 'key.bin')));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pastee_fixed');
    dataDir = Directory(p.join(root.path, 'data'));
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });
  PasteItem item(String id) =>
      PasteItem(id: id, title: 't', content: 'c$id', createdAt: DateTime(2026));

  test('torn keycrc: items survive, no backup, fingerprint rewritten',
      () async {
    var s = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    for (var i = 1; i <= 5; i++) {
      await s.pastes.put(item('$i'));
    }
    await Hive.close();
    await File(p.join(dataDir.path, 'pastes.keycrc')).writeAsString('');
    s = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    expect(s.pastes.getAll(), hasLength(5));
    expect(s.report.unreadableBackup, isNull);
    expect(dataDir.listSync().where((e) => e.path.contains('unreadable')),
        isEmpty);
    expect(File(p.join(dataDir.path, 'pastes.keycrc')).readAsStringSync(),
        isNotEmpty);
  });

  test('torn keycrc AND lost key: the copy is reported and intact', () async {
    var s = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    await s.pastes.put(item('1'));
    await Hive.close();
    final before =
        await File(p.join(dataDir.path, 'pastes.hive')).readAsBytes();
    await File(p.join(dataDir.path, 'pastes.keycrc')).delete();
    await File(p.join(dataDir.path, 'key.bin')).delete();
    s = await Storage.open(dataDir: dataDir, keyStore: keyStore());
    expect(s.pastes.getAll(), isEmpty);
    expect(s.report.unreadableBackup, isNotNull);
    expect(await File(s.report.unreadableBackup!).readAsBytes(), before);
  });

  test('keycrc is not rewritten when unchanged', () async {
    await Storage.open(dataDir: dataDir, keyStore: keyStore());
    await Hive.close();
    final crc = File(p.join(dataDir.path, 'pastes.keycrc'));
    final t1 = crc.statSync().modified;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await Storage.open(dataDir: dataDir, keyStore: keyStore());
    expect(crc.statSync().modified, t1);
  });
}
