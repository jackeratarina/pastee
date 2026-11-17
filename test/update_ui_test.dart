import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/providers/update_provider.dart';
import 'package:pastee/services/update_installer.dart';
import 'package:pastee/services/updates.dart';

import 'support/fakes.dart';
import 'support/update_fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

Finder get updateButton => find.byKey(const ValueKey('updateButton'));
Finder get installButton => find.byKey(const ValueKey('installUpdate'));

/// Pastee 1.4.0, with 1.4.1 out on GitHub (and its checksums).
TestApp appWithUpdate(
    {FakeInstaller? installer, Map<String, Object?>? settings}) {
  final release = makeRelease('1.4.1');
  final releases = FakeReleaseSource([makeRelease('1.4.0'), release]);
  releases.texts[release.checksums!.url] = sumsFor(release);
  return TestApp(
      version: '1.4.0',
      releases: releases,
      installer: installer,
      settings: settings);
}

Future<void> openSettings(WidgetTester tester, Finder target) async {
  await pressShortcut(tester, LogicalKeyboardKey.comma);
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(target, 200,
      scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an update shows in the header soon after Pastee starts',
      (tester) async {
    final app = appWithUpdate();
    await app.pump(tester);
    expect(updateButton, findsNothing);
    expect(app.releases.checks, 0);

    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    expect(app.releases.checks, 1);
    expect(updateButton, findsOneWidget);
    expect(find.byTooltip('Pastee 1.4.1 is available. Click to update.'),
        findsOneWidget);

    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    expect(find.text('Pastee 1.4.1 is available. You have 1.4.0.'),
        findsOneWidget);
    expect(find.textContaining('Pastee updates itself.', findRichText: true),
        findsOneWidget);
    expect(
        find.textContaining('20 Nov 2026', findRichText: true), findsOneWidget);
    expect(
        find.text('Pastee downloads the new version, checks it, replaces its '
            'folder /home/me/apps/pastee and opens again. (9.7 MB)'),
        findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(updateButton, findsOneWidget, reason: 'Later keeps the offer');
  }, variant: mac);

  testWidgets('Skip this version takes it out of the header', (tester) async {
    final app = appWithUpdate();
    await app.pump(tester);
    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip this version'));
    await tester.pumpAndSettle();
    expect(updateButton, findsNothing);
    expect(app.settingsStore.values['update.skipped'], '1.4.1');

    // Settings still has it.
    await openSettings(tester, find.text('Update…'));
    expect(find.text('Pastee 1.4.1 is available. You have 1.4.0.'),
        findsOneWidget);
  }, variant: mac);

  testWidgets('Update and restart downloads, checks, installs and quits',
      (tester) async {
    final app = appWithUpdate();
    await app.pump(tester);
    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();

    app.releases.hold = Completer<void>();
    await tester.tap(installButton);
    await tester.pump();
    // Half of 9.7 MB has arrived.
    expect(find.text('Downloading Pastee 1.4.1… 4.8 MB of 9.7 MB'),
        findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // While it downloads, Esc and the close button don't drop it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(Dialog), findsOneWidget);

    app.releases.hold!.complete();
    await tester.pump();
    await tester.pump();
    expect(app.installer.installs.single.$2.toString(), '1.4.1');
    expect(app.quitCalls, 1);
    expect(find.text('Restarting Pastee…'), findsOneWidget);
    expect(app.settingsStore.values['update.pending'], isA<Map>());
  }, variant: mac);

  testWidgets('Cancel stops the download', (tester) async {
    final app = appWithUpdate();
    await app.pump(tester);
    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    app.releases.hold = Completer<void>();
    await tester.tap(installButton);
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(installButton, findsOneWidget);
    expect(app.installer.installs, isEmpty);
    expect(app.quitCalls, 0);
  }, variant: mac);

  testWidgets('a failed update says why in the dialog', (tester) async {
    final installer = FakeInstaller()
      ..error = const UpdateException('Pastee couldn’t unpack the update.');
    final app = appWithUpdate(installer: installer);
    await app.pump(tester);
    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    await tester.tap(installButton);
    await tester.pumpAndSettle();
    expect(find.text('Pastee couldn’t unpack the update.'), findsOneWidget);
    expect(app.quitCalls, 0);
    expect(installButton, findsOneWidget, reason: 'it can be tried again');
  }, variant: mac);

  testWidgets('a copy that can’t update itself links to the download',
      (tester) async {
    final app = appWithUpdate(
        installer: FakeInstaller(const InstallProbe.unsupported(
            'Pastee is running from its disk image.')));
    await app.pump(tester);
    await tester.pump(UpdateNotifier.startupDelay);
    await tester.pump();
    await tester.tap(updateButton);
    await tester.pumpAndSettle();
    expect(find.text('Pastee is running from its disk image.'), findsOneWidget);
    expect(installButton, findsNothing);
    await tester.tap(find.text('Download from GitHub'));
    await tester.pump();
    expect(app.openedUrls, [makeRelease('1.4.1').page]);
  }, variant: mac);

  testWidgets(
      'Settings shows the version, checks when asked, and can stop '
      'the daily check', (tester) async {
    final app = TestApp(
        version: '1.4.0', releases: FakeReleaseSource([makeRelease('1.4.0')]));
    await app.pump(tester);
    await openSettings(tester, find.text('Check now'));
    expect(find.text('You have Pastee 1.4.0.'), findsOneWidget);

    await tester.tap(find.text('Check now'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Pastee 1.4.0 is up to date. Checked just now.'),
        findsOneWidget);
    expect(app.releases.checks, 1);

    app.releases.error = const UpdateException('Pastee couldn’t reach GitHub.');
    await tester.tap(find.text('Check now'));
    await tester.pump();
    await tester.pump();
    expect(
        find.text('Couldn’t check for updates. Pastee couldn’t reach GitHub.'),
        findsOneWidget);

    await tester.tap(find.text('Check for updates automatically'));
    await tester.pump();
    expect(app.settingsStore.values['checkForUpdates'], false);
    // No automatic check now.
    await tester.pump(const Duration(days: 2));
    expect(app.releases.checks, 2);
  }, variant: mac);

  testWidgets('after an update, Pastee says it worked', (tester) async {
    final page = makeRelease('1.4.1').page;
    final app = TestApp(version: '1.4.1', settings: {
      'update.pending': {
        'from': '1.4.0',
        'to': '1.4.1',
        'at': DateTime.now().millisecondsSinceEpoch,
        'page': '$page',
        'leftovers': <String>[],
      },
    });
    await app.pump(tester);
    await tester.pump();
    expect(find.text('Updated to Pastee 1.4.1'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('What’s new'));
    await tester.pump();
    expect(app.openedUrls, [page]);
  }, variant: mac);

  testWidgets('…and when it didn’t', (tester) async {
    final app = TestApp(version: '1.4.0', settings: {
      'update.pending': {
        'from': '1.4.0',
        'to': '1.4.1',
        'at': DateTime.now().millisecondsSinceEpoch,
      },
    });
    await app.pump(tester);
    await tester.pump();
    expect(
        find.textContaining('couldn’t finish updating to 1.4.1, so this is '
            'still 1.4.0'),
        findsOneWidget);
  }, variant: mac);

  testWidgets('a development build doesn’t update itself', (tester) async {
    final app = TestApp(
      releases: FakeReleaseSource([makeRelease('9.0.0')]),
      settings: {
        'update.newer': [makeRelease('9.0.0').toJson()],
      },
    );
    await app.pump(tester);
    await tester.pump(const Duration(seconds: 30));
    expect(updateButton, findsNothing);
    expect(app.releases.checks, 0);
    await openSettings(tester,
        find.text('This is a development build, so it doesn’t update itself.'));
    expect(find.text('Check now'), findsNothing);
  }, variant: mac);
}
