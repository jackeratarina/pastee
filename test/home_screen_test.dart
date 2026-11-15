import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/hotkey.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/masking.dart';

import 'support/fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final windows = TargetPlatformVariant.only(TargetPlatform.windows);
const both =
    TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows});

Finder get searchField => find.byType(TextField);
Finder get undoButton => find.widgetWithText(SnackBarAction, 'Undo');

void main() {
  testWidgets('primary+V saves the clipboard once, then reports duplicates',
      (tester) async {
    final app = TestApp(clipboard: FakeClipboard('hello from the clipboard'));
    await app.pump(tester);

    await pressShortcut(tester, LogicalKeyboardKey.keyV);
    expect(app.items.single.content, 'hello from the clipboard');
    expect(find.text('hello from the clipboard'), findsWidgets);

    await pressShortcut(tester, LogicalKeyboardKey.keyV);
    expect(app.items, hasLength(1));
    expect(find.text('Already in the list'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  }, variant: both);

  testWidgets('cutting text in the search box does not delete the top item',
      (tester) async {
    final clipboard = SystemClipboardMock()..install(tester);
    final app = TestApp(items: [
      makeItem('alpha one', id: 'a1'),
      makeItem('alpha two', id: 'a2', minutesAgo: 1),
    ]);
    await app.pump(tester);

    await tester.enterText(searchField, 'alpha');
    await tester.pump(const Duration(milliseconds: 300));
    await pressShortcut(tester, LogicalKeyboardKey.keyA);
    await pressShortcut(tester, LogicalKeyboardKey.keyX);
    await tester.pump(const Duration(milliseconds: 300));

    expect(app.items, hasLength(2),
        reason: 'primary+X must cut the search text, not an item');
    expect(clipboard.text, 'alpha');
    expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);
    await tester.pump(const Duration(seconds: 2));
  }, variant: both);

  testWidgets('pasting in the search box pastes into the box', (tester) async {
    final system = SystemClipboardMock()..install(tester);
    system.text = 'needle';
    final app = TestApp(
      items: [makeItem('haystack with a needle', id: 'n')],
      clipboard: FakeClipboard('this must not become an item'),
    );
    await app.pump(tester);

    await tester.tap(searchField);
    await tester.pump();
    await pressShortcut(tester, LogicalKeyboardKey.keyV);
    await tester.pump(const Duration(milliseconds: 300));

    expect(app.items, hasLength(1));
    expect(tester.widget<TextField>(searchField).controller!.text, 'needle');
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('Enter in the search box copies the top result', (tester) async {
    final app = TestApp(items: [
      makeItem('apple pie recipe', id: 'p'),
      makeItem('banana bread', id: 'b', minutesAgo: 1),
    ]);
    await app.pump(tester);

    await tester.enterText(searchField, 'banana');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(app.clipboard.text, 'banana bread');
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('holding Delete removes one item, and primary+Z brings it back',
      (tester) async {
    final app = TestApp(items: [
      makeItem('first', id: '1'),
      makeItem('second', id: '2', minutesAgo: 1),
      makeItem('third', id: '3', minutesAgo: 2),
    ]);
    await app.pump(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(app.items.map((i) => i.id), ['2', '3']);
    expect(undoButton, findsOneWidget);

    await pressShortcut(tester, LogicalKeyboardKey.keyZ);
    expect(app.items.map((i) => i.id), ['1', '2', '3']);
    await tester.pump(const Duration(seconds: 5));
  }, variant: both);

  testWidgets('cut copies the item and can be undone', (tester) async {
    final app = TestApp(items: [makeItem('cut me', id: 'c')]);
    await app.pump(tester);

    await pressShortcut(tester, LogicalKeyboardKey.keyX);
    expect(app.items, isEmpty);
    expect(app.clipboard.text, 'cut me');

    await tester
        .pump(const Duration(milliseconds: 500)); // let the snackbar slide in
    await tester.tap(undoButton);
    await tester.pump();
    expect(app.items.single.id, 'c');
    await tester.pump(const Duration(seconds: 5));
  }, variant: mac);

  testWidgets('passwords are masked, but copying gets the real value',
      (tester) async {
    final app = TestApp(
        items: [makeItem('user: bob\npassword: hunter2!', id: 'login')]);
    await app.pump(tester);

    expect(find.textContaining('hunter2!'), findsNothing);
    expect(find.textContaining(Masker.dots), findsWidgets);
    expect(find.text('Password ••••'), findsOneWidget);

    // Field 2 is the password (field 1 is the username).
    await pressShortcut(tester, LogicalKeyboardKey.digit2);
    expect(app.clipboard.text, 'hunter2!');
    expect(find.text('Copied Password'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await pressShortcut(tester, LogicalKeyboardKey.keyR);
    expect(find.textContaining('hunter2!'), findsWidgets);

    // Revealed text hides itself again.
    await tester.pump(const Duration(seconds: 21));
    expect(find.textContaining('hunter2!'), findsNothing);
  }, variant: mac);

  testWidgets('copied secrets are marked secret and say when they clear',
      (tester) async {
    final clipboard = FakeClipboard()
      ..clearsSecretsAfter = const Duration(seconds: 30);
    final app = TestApp(
        clipboard: clipboard,
        items: [makeItem('user: bob\npassword: hunter2!', id: 'login')]);
    await app.pump(tester);

    await pressShortcut(tester, LogicalKeyboardKey.digit1);
    expect(clipboard.text, 'bob');
    expect(clipboard.lastSecret, isFalse);
    // The note has a hidden password, so the message leaves values out.
    expect(find.text('Copied Username'), findsOneWidget);

    await pressShortcut(tester, LogicalKeyboardKey.digit2);
    expect(clipboard.text, 'hunter2!');
    expect(clipboard.lastSecret, isTrue);
    expect(find.text('Copied Password · clears in 30 s'), findsOneWidget);

    // The whole note contains a password, so copying it is a secret too.
    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, 'user: bob\npassword: hunter2!');
    expect(clipboard.lastSecret, isTrue);
    expect(find.text('Copied to clipboard · clears in 30 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  }, variant: mac);

  testWidgets('a note without secrets is copied normally', (tester) async {
    final clipboard = FakeClipboard()
      ..clearsSecretsAfter = const Duration(seconds: 30);
    final app = TestApp(
        clipboard: clipboard, items: [makeItem('buy milk and eggs', id: 'n')]);
    await app.pump(tester);

    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    expect(clipboard.text, 'buy milk and eggs');
    expect(clipboard.lastSecret, isFalse);
    expect(find.text('Copied to clipboard'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  }, variant: windows);

  testWidgets('everything copied from an "always hide" item is a secret',
      (tester) async {
    final clipboard = FakeClipboard();
    final app = TestApp(clipboard: clipboard, items: [
      makeItem('Host: db.internal\nPort: 5432', id: 's', sensitive: true)
    ]);
    await app.pump(tester);

    await pressShortcut(tester, LogicalKeyboardKey.digit1);
    expect(clipboard.text, 'db.internal');
    expect(clipboard.lastSecret, isTrue);
    await pressShortcut(tester, LogicalKeyboardKey.keyX);
    expect(clipboard.lastSecret, isTrue);
    await tester.pump(const Duration(seconds: 5));
  }, variant: mac);

  testWidgets('settings: "Clear copied secrets" is saved', (tester) async {
    final app = TestApp();
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();

    final dropdown = find.byKey(const ValueKey('clearSecretsAfter'));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    expect(find.text('After 30 seconds'), findsOneWidget);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Never').last);
    await tester.pumpAndSettle();

    expect(app.container.read(settingsProvider).clearSecretsAfter, isNull);
    expect(app.settingsStore.values['clearSecretsAfterSeconds'], 0);
  }, variant: mac);

  testWidgets('the header eye turns masking off and on', (tester) async {
    final app = TestApp(items: [makeItem('pin: 4821', id: 'p')]);
    await app.pump(tester);
    expect(find.textContaining('4821'), findsNothing);

    await tester.tap(find.byIcon(Icons.visibility_off_outlined).first);
    await tester.pump();
    expect(app.container.read(settingsProvider).maskSecrets, isFalse);
    expect(find.textContaining('4821'), findsWidgets);
    expect(app.settingsStore.values['maskSecrets'], false);
  }, variant: mac);

  testWidgets('"always hide" masks a whole item and its auto title',
      (tester) async {
    final app = TestApp(items: [makeItem('my diary entry for today', id: 'd')]);
    await app.pump(tester);
    expect(find.text('my diary entry for today'), findsWidgets);

    await tester.tap(find.byIcon(Icons.lock_open_outlined));
    await tester.pump();

    expect(app.items.single.sensitive, isTrue);
    expect(find.textContaining('my diary'), findsNothing);
    expect(find.text('Hidden item'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('copying from a summoned Pastee hides it again', (tester) async {
    final app = TestApp(items: [makeItem('summon me', id: 's')]);
    await app.pump(tester);

    app.bridge.summon(shown: true);
    await tester.pump();
    expect(app.container.read(summonedProvider), isTrue);

    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.clipboard.text, 'summon me');
    expect(app.bridge.hideCalls, 1);
    expect(app.container.read(summonedProvider), isFalse);

    // Opened normally (not summoned): copying leaves the window alone.
    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.bridge.hideCalls, 1);
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('Escape hides a summoned Pastee', (tester) async {
    final app = TestApp(items: [makeItem('x', id: 'x')]);
    await app.pump(tester);
    app.bridge.summon(shown: true);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(app.bridge.hideCalls, 1);
  }, variant: windows);

  testWidgets('typing while the list has focus starts a search',
      (tester) async {
    final app = TestApp(items: [
      makeItem('kiwi', id: 'k'),
      makeItem('mango', id: 'm', minutesAgo: 1),
    ]);
    await app.pump(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM, character: 'm');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.widget<TextField>(searchField).controller!.text, 'm');
    expect(
        app.container.read(filteredPasteListProvider).map((i) => i.id), ['m']);
  }, variant: mac);

  testWidgets('AltGr (Ctrl+Alt) is not treated as Ctrl on Windows',
      (tester) async {
    final app = TestApp(
      items: [makeItem('a', id: 'a')],
      clipboard: FakeClipboard('should not be pasted'),
    );
    await app.pump(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(app.items, hasLength(1));
  }, variant: windows);

  testWidgets('the recommended shortcut is registered and shown in the header',
      (tester) async {
    final app = TestApp();
    await app.pump(tester);
    await tester.pump();

    final expected = defaultHotKey();
    expect(app.bridge.registered.last, expected);
    expect(find.text(expected.display), findsOneWidget);
  }, variant: both);

  testWidgets('a shortcut another app owns is reported', (tester) async {
    final app = TestApp(
        bridge: FakeBridge(failWith: 'Another app is already using it.'));
    await app.pump(tester);
    await tester.pump();

    expect(find.text('Another app is already using it.'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_alt_outlined), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
  }, variant: mac);

  testWidgets('settings: picking a preset and recording your own shortcut',
      (tester) async {
    final app = TestApp();
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(find.text('Summon shortcut'), findsOneWidget);

    final second = recommendedHotKeys()[1].spec;
    await tester.tap(find.text(second.display));
    await tester.pumpAndSettle();
    expect(app.container.read(settingsProvider).summonHotKey, second);
    expect(app.bridge.registered.last, second);
    expect(app.settingsStore.values['summonHotKey'], second.toJson());

    await tester.tap(find.text('Record'));
    await tester.pump();
    expect(app.bridge.unregisterCalls, greaterThan(0),
        reason: 'recording releases the shortcut');

    // A single modifier is rejected with an explanation.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.textContaining('Use two modifier keys'), findsOneWidget);

    // ⌃⌥K is accepted.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    final custom = app.container.read(settingsProvider).summonHotKey!;
    expect(custom.display, '⌃⌥K');
    expect(custom.keyCode, 0x28); // kVK_ANSI_K
    expect(app.bridge.registered.last, custom);

    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(app.container.read(settingsProvider).summonHotKey, isNull);
    expect(app.settingsStore.values['summonHotKey'], 'off');
  }, variant: mac);

  testWidgets('a long, emoji-heavy paste renders without errors',
      (tester) async {
    final text =
        '${'Meeting moved to 3pm 🎉 see you 👋🏽 ' * 200}\npassword: p🎉ss🎉w0rd';
    final app = TestApp(items: [makeItem(text, id: 'long')]);
    await app.pump(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Meeting moved'), findsWidgets);
  }, variant: mac);
}
