import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/field_config.dart';
import 'package:pastee/providers/field_config_provider.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/pattern_guard.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/ui/field_settings_dialog.dart';
import 'package:pastee/ui/paste_tile.dart';
import 'package:pastee/ui/theme.dart';

import 'support/fakes.dart';
import 'support/field_helpers.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);
const both =
    TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.windows});

/// The Fields & numbers page on its own, with a stand-in speed check.
class FieldsPage {
  FieldsPage({Map<String, Object?>? settings})
      : store = MemorySettingsStore(settings);

  final MemorySettingsStore store;
  late ProviderContainer container;

  /// What the speed check says; a completer lets a test hold it.
  Future<String?> Function(String pattern) speedCheck = (_) async => null;
  final timed = <String>[];

  FieldConfig get config => container.read(fieldConfigProvider);

  Future<void> open(WidgetTester tester,
      {Size size = const Size(600, 800),
      ThemeMode theme = ThemeMode.light}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        patternSpeedCheckProvider.overrideWithValue((pattern) {
          timed.add(pattern);
          return speedCheck(pattern);
        }),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showFieldSettingsDialog(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ));
    container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }
}

Future<void> pickNumber(
    WidgetTester tester, Finder dropdown, String label) async {
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<(int, String)> previewChips(WidgetTester tester) => [
      for (final chip in tester.widgetList<FieldChip>(find.descendant(
          of: find.byKey(const Key('fields-try-it-chips')),
          matching: find.byType(FieldChip))))
        (chip.number, chip.text)
    ];

void main() {
  testWidgets('add, edit, turn off and delete a phrase', (tester) async {
    final page = FieldsPage();
    await page.open(tester);
    expect(find.textContaining('None yet'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('fields-add')));
    expect(find.text('New phrase'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('rule-name')), 'Member ID');
    await tester.enterText(
        find.byKey(const Key('rule-phrases')), 'member id, mã thành viên');
    await pickNumber(tester, find.byKey(const Key('rule-number')), '⌘3');
    expect(find.text('⌘3 copies it from the top item.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rule-save')));
    await tester.pumpAndSettle();

    final added = page.config.custom.single;
    expect(added.name, 'Member ID');
    expect(added.phrases, ['member id', 'mã thành viên']);
    expect(added.number, 3);
    expect(added.enabled, isTrue);
    expect(page.timed, isEmpty, reason: 'no pattern, nothing to time');
    expect(FieldConfig.decode(page.store.values['fields']), page.config);
    expect(find.text('Member ID'), findsOneWidget);
    expect(find.textContaining('“member id”, “mã thành viên”'), findsOneWidget);

    await tapVisible(tester, find.byKey(ValueKey('rule-edit-${added.id}')));
    expect(find.text('Edit phrase'), findsOneWidget);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('rule-phrases')))
            .controller!
            .text,
        'member id, mã thành viên');
    await tester.enterText(find.byKey(const Key('rule-name')), 'Member no.');
    await tester.tap(find.byKey(const Key('rule-secret')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rule-save')));
    await tester.pumpAndSettle();
    final edited = page.config.custom.single;
    expect(edited.id, added.id);
    expect(edited.name, 'Member no.');
    expect(edited.secret, isTrue);
    expect(find.text('Member no.'), findsOneWidget);

    await tapVisible(tester, find.byKey(ValueKey('rule-switch-${added.id}')));
    expect(page.config.custom.single.enabled, isFalse);

    await tapVisible(tester, find.byKey(ValueKey('rule-delete-${added.id}')));
    expect(find.text('Delete “Member no.”?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(page.config.custom, isEmpty);
    expect(page.store.values['fields'], isNull);
    expect(find.textContaining('None yet'), findsOneWidget);
  }, variant: mac);

  testWidgets('the editor checks the name, phrases and pattern',
      (tester) async {
    final page = FieldsPage();
    await page.open(tester);
    await tapVisible(tester, find.byKey(const Key('fields-add')));
    final save = find.byKey(const Key('rule-save'));

    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Give it a name.'), findsOneWidget);
    expect(
        find.text('Add a phrase, a value pattern, or both.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('rule-name')), 'Customer');
    await tester.enterText(find.byKey(const Key('rule-pattern')), '(KH-');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('This isn’t a valid pattern: unterminated group.'),
        findsOneWidget);
    await tester.enterText(find.byKey(const Key('rule-pattern')), r'\d*');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('can match an empty value'), findsOneWidget);
    expect(page.timed, isEmpty, reason: 'quick checks come first');

    // Too slow: the speed check says so, and nothing is saved.
    page.speedCheck = (_) async => PatternGuard.tooSlow;
    await tester.enterText(find.byKey(const Key('rule-pattern')), r'(\d+)+$');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text(PatternGuard.tooSlow), findsOneWidget);
    expect(page.config.custom, isEmpty);

    // While it is being timed the button says so.
    final verdict = Completer<String?>();
    page.speedCheck = (_) => verdict.future;
    await tester.enterText(
        find.byKey(const Key('rule-pattern')), r'KH-(\d{4,})');
    await tester.tap(save);
    await tester.pump();
    expect(find.text('Checking…'), findsOneWidget);
    verdict.complete(null);
    await tester.pumpAndSettle();
    expect(page.config.custom.single.pattern, r'KH-(\d{4,})');
    expect(page.config.custom.single.phrases, isEmpty);
    expect(page.timed.last, r'KH-(\d{4,})');
    expect(find.textContaining('Every match of the pattern'), findsOneWidget);

    // Editing something else doesn't time a saved pattern again.
    final count = page.timed.length;
    await tapVisible(tester,
        find.byKey(ValueKey('rule-edit-${page.config.custom.single.id}')));
    await tester.enterText(find.byKey(const Key('rule-name')), 'Customer no.');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(page.config.custom.single.name, 'Customer no.');
    expect(page.timed, hasLength(count));
  }, variant: mac);

  testWidgets('built-in fields: on/off and a number', (tester) async {
    final page = FieldsPage();
    await page.open(tester);

    await pickNumber(
        tester, find.byKey(const ValueKey('builtin-number-email')), '⌘2');
    expect(page.config[BuiltInField.email].number, 2);

    await tapVisible(
        tester, find.byKey(const ValueKey('builtin-switch-password')));
    expect(page.config[BuiltInField.password].enabled, isFalse);
    expect(find.text('Off: no chip or number, but still hidden behind dots.'),
        findsOneWidget);
    final dropdown = tester.widget<DropdownButton<int>>(find.descendant(
        of: find.byKey(const ValueKey('builtin-number-password')),
        matching: find.byType(DropdownButton<int>)));
    expect(dropdown.onChanged, isNull, reason: 'no number while it is off');

    await tapVisible(tester, find.byKey(const Key('builtin-lines')));
    expect(page.config.numberLines, isFalse);
    expect(FieldConfig.decode(page.store.values['fields']), page.config);

    // Two fields wanting one number are pointed out.
    await page.container
        .read(fieldConfigProvider.notifier)
        .saveRule(rule('Member', phrases: ['member'], number: 2));
    await tester.pumpAndSettle();
    expect(find.textContaining('⌘2: Member and Emails both want it'),
        findsOneWidget);

    await tapVisible(tester, find.text('Reset to defaults…'));
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(page.config, FieldConfig.defaults);
  }, variant: mac);

  testWidgets('try it shows the chips and their numbers, live', (tester) async {
    final page = FieldsPage();
    await page.open(tester);
    await tester.enterText(find.byKey(const Key('fields-try-it')),
        'email: a@b.co\nMember ID: M-42\npassword: hunter2!');
    await tester.pump();
    expect(previewChips(tester),
        [(1, 'a@b.co'), (2, 'M-42'), (3, 'Password ••••')]);

    await page.container
        .read(fieldConfigProvider.notifier)
        .saveRule(rule('Member ID', phrases: ['member id'], number: 1));
    await tester.pump();
    expect(previewChips(tester), [
      (1, 'Member ID: M-42'),
      (2, 'a@b.co'),
      (3, 'Password ••••'),
    ]);

    await tapVisible(
        tester, find.byKey(const ValueKey('builtin-switch-email')));
    expect(
        previewChips(tester), [(1, 'Member ID: M-42'), (2, 'Password ••••')]);

    await tester.enterText(find.byKey(const Key('fields-try-it')), '   ');
    await tester.pump();
    expect(find.byType(FieldChip), findsNothing);
  }, variant: mac);

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('fits the smallest window (${theme.name})', (tester) async {
      final page = FieldsPage(settings: {
        'fields': configWith(
          [
            rule('A rather long name for a field',
                phrases: ['some phrase', 'another phrase', 'a third one'],
                pattern: r'[A-Z]{2}\d{6}',
                secret: true,
                number: 9),
          ],
          builtIn: {
            BuiltInField.password: const BuiltInFieldSetting(enabled: false),
            BuiltInField.email: const BuiltInFieldSetting(number: 9),
          },
        ).encode(),
      });
      await page.open(tester, size: const Size(420, 440), theme: theme);
      final tryIt = find.byKey(const Key('fields-try-it'));
      await tester.ensureVisible(tryIt);
      await tester.enterText(
          tryIt,
          'some phrase: AB123456\nemail: someone.with.a.long.name@example.com\n'
          'https://example.com/a/very/long/path/that/goes/on\nPIN: 4821');
      await tester.pumpAndSettle();
      expect(find.byType(FieldChip), findsWidgets);

      await tapVisible(tester, find.byKey(const Key('fields-add')));
      await tester.tap(find.byKey(const Key('rule-save')));
      await tester.pumpAndSettle();
      expect(find.text('Give it a name.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, variant: both);
  }

  testWidgets('Settings opens Fields & numbers', (tester) async {
    final app = TestApp();
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    final entry = find.text('Fields & numbers…');
    await tester.scrollUntilVisible(entry, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('Fields & numbers'), findsOneWidget);
    expect(find.text('Your phrases'), findsOneWidget);
    expect(find.text('Built-in fields'), findsOneWidget);
  }, variant: mac);

  group('the home screen', () {
    final member = configWith([
      rule('Member', phrases: ['ma thanh vien'], number: 3)
    ]);
    const note = 'Email: a@b.co\nMã thành viên: TV-0042\nhttps://example.com/x';

    testWidgets('a phrase given 3 is copied with ⌘3 / Ctrl+3', (tester) async {
      final app = TestApp(
        items: [makeItem(note, id: 'n')],
        settings: {'fields': member.encode()},
      );
      await app.pump(tester);
      expect(find.text('Member: TV-0042'), findsOneWidget);
      final chip = tester.widget<FieldChip>(find.ancestor(
          of: find.text('Member: TV-0042'), matching: find.byType(FieldChip)));
      expect(chip.number, 3);

      await pressShortcut(tester, LogicalKeyboardKey.digit3);
      expect(app.clipboard.text, 'TV-0042');
      expect(find.text('Copied Member: TV-0042'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      await pressShortcut(tester, LogicalKeyboardKey.digit1);
      expect(app.clipboard.text, 'a@b.co');
      await tester.pump(const Duration(seconds: 2));
      await pressShortcut(tester, LogicalKeyboardKey.digit2);
      expect(app.clipboard.text, 'https://example.com/x');
      await tester.pump(const Duration(seconds: 2));
    }, variant: both);

    testWidgets('a number nothing has says so', (tester) async {
      final app = TestApp(
        items: [makeItem('Seat: 12A', id: 's')],
        settings: {
          'fields': configWith([
            rule('Seat', phrases: ['seat'], number: 7)
          ]).encode(),
        },
      );
      await app.pump(tester);
      await pressShortcut(tester, LogicalKeyboardKey.digit1);
      expect(find.text('The top item has no field 1'), findsOneWidget);
      expect(app.clipboard.text, isNull);
      await tester.pump(const Duration(seconds: 2));
      await pressShortcut(tester, LogicalKeyboardKey.digit7);
      expect(app.clipboard.text, '12A');
      await tester.pump(const Duration(seconds: 2));
    }, variant: mac);

    testWidgets('long chips fit the smallest window', (tester) async {
      final app = TestApp(
        items: [
          makeItem('Mã thành viên: ${'TV-0042-ABCDEFGHIJ' * 3}\n$note', id: 'n')
        ],
        settings: {
          'fields': configWith([
            rule('A long name for my field',
                phrases: ['ma thanh vien'], number: 3),
          ]).encode(),
        },
      );
      await app.pump(tester);
      await tester.binding.setSurfaceSize(const Size(420, 440));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Both lines with the phrase; the chip text is cut to 32 characters.
      expect(find.text('A long name for my field: TV-00…'), findsNWidgets(2));
    }, variant: mac);

    testWidgets('changing the settings updates the list', (tester) async {
      final app = TestApp(items: [makeItem('Locker: K7Q9X', id: 'l')]);
      await app.pump(tester);
      expect(find.text('K7Q9X'), findsOneWidget);

      final fields = app.container.read(fieldConfigProvider.notifier);
      await fields.saveRule(rule('My locker', phrases: ['locker']));
      await tester.pump();
      expect(find.text('My locker: K7Q9X'), findsOneWidget);

      await fields
          .saveRule(rule('My locker', phrases: ['locker'], secret: true));
      await tester.pump();
      expect(find.text('My locker ••••'), findsOneWidget);
      expect(find.textContaining('K7Q9X'), findsNothing);
      await pressShortcut(tester, LogicalKeyboardKey.digit1);
      expect(app.clipboard.text, 'K7Q9X');
      expect(find.text('Copied My locker'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    }, variant: mac);
  });
}
