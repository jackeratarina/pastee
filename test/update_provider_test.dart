import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pastee/providers/update_provider.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/services/update_installer.dart';
import 'package:pastee/services/updates.dart';

import 'support/update_fakes.dart';

class Harness {
  Harness({
    String? current = '1.4.0',
    Map<String, Object?>? stored,
    List<Release>? releases,
    InstallProbe? probe,
    this.automatic = true,
  })  : store = MemorySettingsStore(stored),
        source = FakeReleaseSource(releases),
        installer = FakeInstaller(probe) {
    notifier = UpdateNotifier(
      store: store,
      source: source,
      installer: installer,
      current: Version.tryParse(current),
      automatic: () => automatic,
      quit: () async => quits++,
      now: () => now,
    );
    notifier.addListener((state) => _state = state);
    addTearDown(notifier.dispose);
  }

  final MemorySettingsStore store;
  final FakeReleaseSource source;
  final FakeInstaller installer;
  late final UpdateNotifier notifier;
  bool automatic;
  int quits = 0;
  DateTime now = DateTime(2026, 11, 20, 9);

  late UpdateState _state;
  UpdateState get state => _state;
}

List<String> versions(List<Release> releases) =>
    [for (final release in releases) '${release.version}'];

void main() {
  final latest = makeRelease('1.4.1');

  test('a development build never checks or offers anything', () async {
    final h = Harness(current: null, releases: [latest]);
    h.notifier.checkIfDue();
    await h.notifier.check();
    expect(h.source.checks, 0);
    expect(h.state.current, isNull);
    expect(h.state.offered, isFalse);
  });

  test('finds the newer releases and remembers them', () async {
    final h = Harness(releases: [
      makeRelease('1.3.0'),
      makeRelease('1.4.0'),
      latest,
      makeRelease('1.5.0'),
    ]);
    h.notifier.checkIfDue();
    expect(h.state.stage, UpdateStage.checking);
    await h.notifier.check();
    expect(h.source.checks, 1, reason: 'one check at a time');
    expect(versions(h.state.newer), ['1.5.0', '1.4.1']);
    expect(h.state.latest?.version, const Version(1, 5, 0));
    expect(h.state.offered, isTrue);
    expect(h.state.lastChecked, h.now);
    expect(h.state.stage, UpdateStage.idle);
    expect(h.store.values['update.lastCheck'], h.now.millisecondsSinceEpoch);
    expect(h.store.values['update.newer'], hasLength(2));

    // After a restart, before the next check.
    final again = Harness(stored: h.store.values);
    expect(versions(again.state.newer), ['1.5.0', '1.4.1']);
    expect(again.state.lastChecked, h.now);
    // …and after updating to 1.4.1, only what's newer than that.
    final updated = Harness(current: '1.4.1', stored: h.store.values);
    expect(versions(updated.state.newer), ['1.5.0']);
  });

  test('up to date: nothing is offered and nothing is cached', () async {
    final h = Harness(releases: [makeRelease('1.4.0'), makeRelease('1.3.0')]);
    await h.notifier.check();
    expect(h.state.newer, isEmpty);
    expect(h.state.offered, isFalse);
    expect(h.store.values['update.newer'], isNull);
    expect(h.state.lastChecked, h.now);
  });

  test('checks by itself once a day, if allowed', () async {
    final h = Harness(releases: [latest]);
    h.notifier.checkIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(h.source.checks, 1);

    h.now = h.now.add(const Duration(hours: 23));
    h.notifier.checkIfDue();
    expect(h.source.checks, 1);

    h.now = h.now.add(const Duration(hours: 1));
    h.notifier.checkIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(h.source.checks, 2);

    h.automatic = false;
    h.now = h.now.add(const Duration(days: 3));
    h.notifier.checkIfDue();
    expect(h.source.checks, 2);
    // Asking still works.
    await h.notifier.check();
    expect(h.source.checks, 3);
  });

  test('a clock set back doesn’t stop the checks', () async {
    final h = Harness(releases: [
      latest
    ], stored: {
      'update.lastCheck':
          DateTime(2027, 1, 1).millisecondsSinceEpoch, // in the "future"
    });
    h.notifier.checkIfDue();
    await Future<void>.delayed(Duration.zero);
    expect(h.source.checks, 1);
  });

  test('a failed check says why and keeps what was known', () async {
    final h = Harness(releases: [latest]);
    await h.notifier.check();
    h.source.error = const UpdateException('Pastee couldn’t reach GitHub.');
    h.now = h.now.add(const Duration(days: 2));
    await h.notifier.check();
    expect(h.state.checkError, 'Pastee couldn’t reach GitHub.');
    expect(versions(h.state.newer), ['1.4.1']);
    expect(h.state.lastChecked, DateTime(2026, 11, 20, 9),
        reason: 'a failed check is retried within the hour');
    h.source.error = StateError('odd');
    await h.notifier.check();
    expect(h.state.checkError, contains('odd'));
    h.source.error = null;
    await h.notifier.check();
    expect(h.state.checkError, isNull);
  });

  test('a skipped version is offered again only when a newer one comes',
      () async {
    final h = Harness(releases: [latest]);
    await h.notifier.check();
    await h.notifier.skip();
    expect(h.state.offered, isFalse);
    expect(h.state.latest, isNotNull, reason: 'Settings still shows it');
    expect(h.store.values['update.skipped'], '1.4.1');
    expect(Harness(stored: h.store.values).state.offered, isFalse);

    h.source.published = [latest, makeRelease('1.4.2')];
    await h.notifier.check();
    expect(h.state.offered, isTrue);
  });

  group('installing', () {
    Future<Harness> ready({InstallProbe? probe, Release? release}) async {
      final h = Harness(releases: [release ?? latest], probe: probe);
      await h.notifier.check();
      final sums = h.state.latest!.checksums;
      if (sums != null) h.source.texts[sums.url] = sumsFor(h.state.latest!);
      return h;
    }

    test('downloads, checks, installs and quits', () async {
      final h = await ready();
      await h.notifier.install();
      expect(h.source.downloads.single.path,
          endsWith('/v1.4.1/Pastee-1.4.1-linux-x64.tar.gz'));
      expect(h.installer.installs.single.$1,
          p.join(FakeInstaller.workspace, 'Pastee-1.4.1-linux-x64.tar.gz'));
      expect(h.installer.installs.single.$2, const Version(1, 4, 1));
      expect(h.quits, 1);
      expect(h.state.stage, UpdateStage.restarting);
      expect(h.state.installError, isNull);
      expect(h.installer.discarded, [FakeInstaller.workspace],
          reason: 'the download isn’t needed once it’s unpacked');
      final pending = h.store.values['update.pending'] as Map;
      expect(pending['from'], '1.4.0');
      expect(pending['to'], '1.4.1');
      expect(pending['page'], '${latest.page}');
      expect(pending['leftovers'], isEmpty);
    });

    test('keeps what the installer’s helper still needs', () async {
      final h = await ready();
      h.installer.keep = [FakeInstaller.workspace];
      await h.notifier.install();
      expect(h.installer.discarded, isEmpty);
      expect((h.store.values['update.pending'] as Map)['leftovers'],
          [FakeInstaller.workspace]);
    });

    test('a damaged download isn’t installed', () async {
      final h = await ready();
      h.source.receivedSha = List.filled(64, '0').join();
      await h.notifier.install();
      expect(h.state.installError, contains('checksum doesn’t match'));
      expect(h.installer.installs, isEmpty);
      expect(h.quits, 0);
      expect(h.state.stage, UpdateStage.idle);
      expect(h.installer.discarded, [FakeInstaller.workspace]);
    });

    test('a release without checksums isn’t even downloaded', () async {
      final unsafe = makeRelease('1.4.1', withSums: false);
      final h = Harness(releases: [
        Release(
          version: unsafe.version,
          tag: unsafe.tag,
          notes: unsafe.notes,
          page: unsafe.page,
          assets: [
            for (final asset in unsafe.assets)
              ReleaseAsset(name: asset.name, url: asset.url, size: asset.size),
          ],
        ),
      ]);
      await h.notifier.check();
      await h.notifier.install();
      expect(h.state.installError, contains('no checksum'));
      expect(h.source.downloads, isEmpty);
      expect(h.quits, 0);
    });

    test('checksums that disagree stop it too', () async {
      final h = await ready();
      h.source.texts[h.state.latest!.checksums!.url] =
          sumsFor(h.state.latest!, sha: List.filled(64, 'f').join());
      await h.notifier.install();
      expect(h.state.installError, contains('don’t agree'));
      expect(h.source.downloads, isEmpty);
    });

    test('SHA256SUMS.txt that can’t be fetched stops it', () async {
      final h = await ready();
      h.source.texts.clear();
      await h.notifier.install();
      expect(h.state.installError, contains('404'));
      expect(h.source.downloads, isEmpty);
    });

    test('says when the release has nothing for this computer', () async {
      final h = await ready(
          probe: const InstallProbe.target(InstallTarget(
              kind: InstallKind.linuxDeb,
              path: '/opt/pastee',
              assetSuffix: '-linux-x64.deb')));
      await h.notifier.install();
      expect(h.state.installError, contains('-linux-x64.deb'));
      expect(h.source.downloads, isEmpty);
    });

    test('says why a copy can’t update itself', () async {
      final h = await ready(
          probe: const InstallProbe.unsupported('Pastee is on a disk image.'));
      await h.notifier.install();
      expect(h.state.installError, 'Pastee is on a disk image.');
      expect(h.source.downloads, isEmpty);
    });

    test('cancelling stops the download', () async {
      final h = await ready();
      h.source.hold = Completer<void>();
      final install = h.notifier.install();
      await Future<void>.delayed(Duration.zero);
      expect(h.state.stage, UpdateStage.downloading);
      expect(h.state.received, h.state.size ~/ 2);
      expect(h.state.busy, isTrue);
      h.notifier.cancel();
      await install;
      expect(h.state.stage, UpdateStage.idle);
      expect(h.state.installError, isNull);
      expect(h.installer.installs, isEmpty);
      expect(h.installer.discarded, [FakeInstaller.workspace]);
      expect(h.quits, 0);
    });

    test('a check that ends during a download doesn’t interrupt it', () async {
      final h = await ready();
      h.source.hold = Completer<void>();
      // The daily check starts…
      final newest = makeRelease('1.4.2');
      h.source.published = [latest, newest];
      h.source.texts[newest.checksums!.url] = sumsFor(newest);
      final check = h.notifier.check();
      expect(h.state.stage, UpdateStage.checking);
      // …and the user clicks Update and restart before it's back.
      final install = h.notifier.install();
      await Future<void>.delayed(Duration.zero);
      expect(h.state.stage, UpdateStage.downloading);
      await check;
      expect(h.state.stage, UpdateStage.downloading);
      expect(versions(h.state.newer), ['1.4.2', '1.4.1']);
      h.source.hold!.complete();
      await install;
      expect(h.installer.installs.single.$2, const Version(1, 4, 2));
      expect(h.quits, 1);
    });

    test('installs what GitHub offers now, not what the last check found',
        () async {
      final h = await ready();
      // 1.4.2 came out since the check…
      final newest = makeRelease('1.4.2');
      h.source.published = [latest, newest];
      h.source.texts[newest.checksums!.url] = sumsFor(newest);
      await h.notifier.install();
      expect(h.source.checks, 2);
      expect(h.installer.installs.single.$2, const Version(1, 4, 2));
      expect(h.source.downloads.single.path, contains('/v1.4.2/'));
    });

    test('a release pulled since the check isn’t installed', () async {
      final h = await ready();
      h.source.published = [makeRelease('1.4.0')];
      await h.notifier.install();
      expect(h.state.installError, contains('no longer offers'));
      expect(h.state.newer, isEmpty);
      expect(h.state.offered, isFalse);
      expect(h.source.downloads, isEmpty);
      expect(h.quits, 0);
    });

    test('says so when GitHub can’t be reached just before downloading',
        () async {
      final h = await ready();
      h.source.error = const UpdateException('Pastee couldn’t reach GitHub.');
      await h.notifier.install();
      expect(h.state.installError, 'Pastee couldn’t reach GitHub.');
      expect(h.state.stage, UpdateStage.idle);
      expect(h.source.downloads, isEmpty);
    });

    test('an installer that fails leaves Pastee running, saying why', () async {
      final h = await ready();
      h.installer.error = const UpdateException('Pastee couldn’t unpack it.');
      await h.notifier.install();
      expect(h.state.installError, 'Pastee couldn’t unpack it.');
      expect(h.quits, 0);
      expect(h.store.values['update.pending'], isNull);
      // …and trying again starts over.
      h.installer.error = null;
      await h.notifier.install();
      expect(h.quits, 1);
    });
  });

  group('after a restart', () {
    Map<String, Object?> pending(
            {int? at, List<String> leftovers = const []}) =>
        {
          'update.pending': {
            'from': '1.4.0',
            'to': '1.4.1',
            'at': at ?? DateTime(2026, 11, 20, 8, 59).millisecondsSinceEpoch,
            'page': '${latest.page}',
            'leftovers': leftovers,
          },
        };

    test('says the update worked, once', () {
      final h = Harness(current: '1.4.1', stored: pending());
      expect(h.state.notice?.installed, isTrue);
      expect(h.state.notice?.version, const Version(1, 4, 1));
      expect(h.state.notice?.page, latest.page);
      expect(h.store.values['update.pending'], isNull);
      h.notifier.clearNotice();
      expect(h.state.notice, isNull);
      expect(Harness(current: '1.4.1', stored: h.store.values).state.notice,
          isNull);
    });

    test('says when the old version is still running', () {
      final h = Harness(current: '1.4.0', stored: pending());
      expect(h.state.notice?.installed, isFalse);
      expect(h.state.notice?.version, const Version(1, 4, 1));
    });

    test('an old or odd record is no news', () {
      expect(
          Harness(
                  current: '1.4.1',
                  stored: pending(
                      at: DateTime(2026, 11, 10).millisecondsSinceEpoch))
              .state
              .notice,
          isNull);
      expect(Harness(current: '1.5.0', stored: pending()).state.notice, isNull);
      expect(
          Harness(current: '1.4.1', stored: {'update.pending': 'junk'})
              .state
              .notice,
          isNull);
    });

    test('tidies up what the update left behind', () async {
      final h = Harness(
          current: '1.4.1',
          stored: pending(leftovers: [r'C:\Temp\pastee-update-1']));
      expect(h.installer.discarded, isEmpty);
      await h.notifier.cleanUp();
      expect(h.installer.discarded, [r'C:\Temp\pastee-update-1']);
      expect(h.store.values['update.leftovers'], isNull);
    });
  });
}
