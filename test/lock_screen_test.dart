import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/app_lock.dart';
import 'package:pastee/ui/settings_dialog.dart';

import 'support/fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

Finder get passcodeField => find.widgetWithText(TextField, 'Passcode');

Future<void> enterPasscode(WidgetTester tester, String passcode) async {
  await tester.enterText(passcodeField, passcode);
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await tester.pump();
}

Future<TestApp> lockedApp(WidgetTester tester,
    {FakeAuthenticator? authenticator,
    bool deviceUnlock = false,
    String timeout = 'fiveMinutes',
    FakeClipboard? clipboard}) async {
  final app = TestApp(
    items: [makeItem('user: bob\npassword: hunter2!', id: 'login')],
    settings: await lockedSettings('2580',
        deviceUnlock: deviceUnlock, timeout: timeout),
    authenticator: authenticator,
    clipboard: clipboard,
  );
  await app.pump(tester);
  await tester.pump();
  return app;
}

void main() {
  testWidgets('a locked Pastee shows nothing and ignores shortcuts',
      (tester) async {
    final clipboard = FakeClipboard('clipboard text');
    final app = await lockedApp(tester, clipboard: clipboard);

    expect(find.text('Pastee is locked'), findsOneWidget);
    expect(find.textContaining('bob'), findsNothing);
    expect(find.textContaining('hunter2'), findsNothing);

    await pressShortcut(tester, LogicalKeyboardKey.keyV);
    await pressShortcut(tester, LogicalKeyboardKey.digit2);
    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    expect(app.items, hasLength(1), reason: 'Cmd+V must not save while locked');
    expect(clipboard.text, 'clipboard text',
        reason: 'nothing copied while locked');
  }, variant: mac);

  testWidgets('wrong passcode, then the right one', (tester) async {
    await lockedApp(tester);
    await enterPasscode(tester, '0000');
    expect(find.text('Wrong passcode.'), findsOneWidget);
    expect(find.text('Pastee is locked'), findsOneWidget);

    await enterPasscode(tester, '2580');
    expect(find.text('Pastee is locked'), findsNothing);
    expect(find.textContaining('bob'), findsWidgets);
  }, variant: mac);

  testWidgets('too many wrong passcodes start a countdown', (tester) async {
    await lockedApp(tester);
    for (var i = 0; i < 5; i++) {
      await enterPasscode(tester, '0000');
    }
    expect(find.text('Try again in 0:30'), findsOneWidget);
    expect(tester.widget<TextField>(passcodeField).enabled, isFalse);

    await tester.pump(const Duration(seconds: 31));
    expect(tester.widget<TextField>(passcodeField).enabled, isTrue);
    await enterPasscode(tester, '2580');
    expect(find.text('Pastee is locked'), findsNothing);
  }, variant: mac);

  testWidgets('Touch ID unlocks straight away when turned on', (tester) async {
    final device = FakeAuthenticator(available: true, succeeds: true);
    await lockedApp(tester, authenticator: device, deviceUnlock: true);
    await tester.pump();
    expect(device.prompts, 1);
    expect(find.text('Pastee is locked'), findsNothing);
  }, variant: mac);

  testWidgets('a cancelled Touch ID prompt leaves the lock and a retry button',
      (tester) async {
    final device = FakeAuthenticator(available: true, succeeds: false);
    await lockedApp(tester, authenticator: device, deviceUnlock: true);
    await tester.pump();
    expect(find.text('Pastee is locked'), findsOneWidget);
    expect(device.prompts, 1, reason: 'asks once, never in a loop');

    device.succeeds = true;
    await tester.tap(find.text('Unlock with Touch ID'));
    await tester.pump();
    expect(find.text('Pastee is locked'), findsNothing);
  }, variant: mac);

  testWidgets('set up App Lock in Settings, then lock with Cmd+L',
      (tester) async {
    final app = TestApp(items: [makeItem('secret note', id: 's')]);
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Set a passcode…'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'New passcode'), '12');
    await tester.enterText(
        find.widgetWithText(TextField, 'Repeat the passcode'), '12');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('at least 4 characters'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'New passcode'), '2580');
    await tester.enterText(
        find.widgetWithText(TextField, 'Repeat the passcode'), '2580');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(app.container.read(appLockProvider).enabled, isTrue);
    expect(app.container.read(appLockProvider).locked, isFalse);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await pressShortcut(tester, LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(find.text('Pastee is locked'), findsOneWidget);
    expect(find.textContaining('secret note'), findsNothing);
  }, variant: mac);

  testWidgets('locking closes open dialogs and snackbars', (tester) async {
    final app = await lockedApp(tester);
    await enterPasscode(tester, '2580');
    await pressShortcut(tester, LogicalKeyboardKey.keyC); // shows a snackbar
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsOneWidget);

    app.container.read(appLockProvider.notifier).lock();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Pastee is locked'), findsOneWidget);
  }, variant: mac);

  testWidgets('"as soon as hidden" locks when the window hides',
      (tester) async {
    await lockedApp(tester, timeout: LockTimeout.immediately.name);
    await enterPasscode(tester, '2580');
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Pastee is locked'), findsNothing,
        reason: 'only lost focus');
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(find.text('Pastee is locked'), findsOneWidget);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }, variant: mac);

  testWidgets('turning App Lock off needs the passcode', (tester) async {
    final app = await lockedApp(tester);
    await enterPasscode(tester, '2580');
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn off…'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Current passcode'), '1111');
    await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
    await tester.pump();
    expect(find.text('Wrong passcode.'), findsOneWidget);
    expect(app.container.read(appLockProvider).enabled, isTrue);

    await tester.enterText(
        find.widgetWithText(TextField, 'Current passcode'), '2580');
    await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
    await tester.pumpAndSettle();
    expect(app.container.read(appLockProvider).enabled, isFalse);
    expect(app.settingsStore.values['lock.passcode'], isNull);
  }, variant: mac);

  testWidgets('"Forgot passcode?" erases the items and turns the lock off',
      (tester) async {
    final app = await lockedApp(tester);
    await tester.tap(find.text('Forgot passcode?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Erase all items'));
    await tester.pumpAndSettle();

    expect(app.items, isEmpty);
    expect(app.store.getAll(), isEmpty);
    expect(app.container.read(appLockProvider).enabled, isFalse);
    expect(find.text('Pastee is locked'), findsNothing);
  }, variant: mac);
}
