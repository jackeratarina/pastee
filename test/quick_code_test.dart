import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/paste_item.dart';
import 'package:pastee/model/quick_code.dart';
import 'package:pastee/providers/providers.dart';
import 'package:pastee/services/field_extractor.dart';
import 'package:pastee/services/quick_codes.dart';
import 'package:pastee/services/storage_service.dart';
import 'package:pastee/ui/paste_tile.dart';

import 'support/fakes.dart';

const note = 'silvertiger\n'
    'user: tiger@example.com\n'
    'password: hunter2!';

/// The code a right-click on the note's password chip would save.
QuickCode codeForPassword(String code, [String content = note]) {
  final field = FieldExtractor.extract(content)
      .fields
      .firstWhere((f) => f.kind == FieldKind.password);
  return QuickCode(code: code, start: field.span.start, end: field.span.end);
}

PasteItem withCodes(PasteItem item, List<QuickCode> codes) =>
    item.copyWith(quickCodes: codes);

Finder get searchField => find.byType(TextField);

Finder chipWhere(bool Function(FieldChip chip) test) =>
    find.byWidgetPredicate((widget) => widget is FieldChip && test(widget),
        description: 'field chip');

Finder get passwordChip =>
    chipWhere((chip) => chip.text.startsWith('Password'));

Future<void> typeInSearch(WidgetTester tester, String text) async {
  await tester.enterText(searchField, text);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> pressEnter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  group('QuickCode', () {
    test('matching ignores case, spaces around it and accent encoding', () {
      expect(QuickCode.normalize('  ST2 '), 'st2');
      // "ế" precomposed and as e + circumflex + acute (Unikey's combining
      // mode) are the same code.
      expect(QuickCode.normalize('Thế'), QuickCode.normalize('thế'));
    });

    test('codes from one character, without spaces, up to 32 characters', () {
      expect(QuickCode.problemWith('s'), isNull);
      expect(QuickCode.problemWith('st2'), isNull);
      expect(QuickCode.problemWith(' st2 '), isNull);
      expect(QuickCode.problemWith(''), isNotNull);
      expect(QuickCode.problemWith('   '), isNotNull);
      expect(QuickCode.problemWith('st 2'), isNotNull);
      expect(QuickCode.problemWith('x' * 32), isNull);
      expect(QuickCode.problemWith('x' * 33), isNotNull);
      expect(QuickCode.problemWith('🐯' * 32), isNull,
          reason: 'counted in characters, not UTF-16 units');
    });

    test('JSON round trip; damaged entries are refused', () {
      const code = QuickCode(code: 'st2', start: 3, end: 9);
      expect(QuickCode.fromJson(code.toJson()), code);
      expect(QuickCode.fromJson(null), isNull);
      expect(QuickCode.fromJson('st2'), isNull);
      expect(QuickCode.fromJson({'c': 'st2', 's': 3}), isNull);
      expect(QuickCode.fromJson({'c': '', 's': 3, 'e': 9}), isNull);
      expect(QuickCode.fromJson({'c': 'a b', 's': 3, 'e': 9}), isNull);
      expect(QuickCode.fromJson({'c': 'st2', 's': 9, 'e': 3}), isNull);
      expect(QuickCode.fromJson({'c': 'st2', 's': -1, 'e': 3}), isNull);
    });
  });

  group('finding the field of a code', () {
    test('the field at the same place, else one overlapping it', () {
      final extraction = FieldExtractor.extract(note);
      final password =
          extraction.fields.indexWhere((f) => f.kind == FieldKind.password);
      final code = codeForPassword('st2');
      expect(quickCodeFieldIndex(code, extraction), password);

      final shifted =
          QuickCode(code: 'st2', start: code.start - 2, end: code.end - 1);
      expect(quickCodeFieldIndex(shifted, extraction), password);

      // "user" of "user: tiger@…" is a label, not part of any field.
      const nowhere = QuickCode(code: 'x', start: 12, end: 16);
      expect(note.substring(12, 16), 'user');
      expect(quickCodeFieldIndex(nowhere, extraction), -1);
    });

    test('a field shows the code set exactly on it first', () {
      final extraction = FieldExtractor.extract(note);
      final password =
          extraction.fields.indexWhere((f) => f.kind == FieldKind.password);
      final exact = codeForPassword('st2');
      final overlapping =
          QuickCode(code: 'old', start: exact.start + 1, end: exact.end);
      expect(
          quickCodesOfField([overlapping, exact], extraction, password).first,
          exact);
      expect(quickCodesOfField([exact], extraction, 99), isEmpty);
    });
  });

  group('storing codes', () {
    ProviderContainer container(List<PasteItem> items) {
      final c = ProviderContainer(overrides: [
        pasteStoreProvider.overrideWithValue(MemoryPasteStore(items)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('set, change and remove a code; codes are unique in any case',
        () async {
      final c = container([
        makeItem(note, id: 'tiger'),
        makeItem('wifi password: n0tGuessable', id: 'wifi', minutesAgo: 1),
      ]);
      final notifier = c.read(pasteListProvider.notifier);
      PasteItem item(String id) =>
          c.read(pasteListProvider).firstWhere((i) => i.id == id);

      final st2 = codeForPassword('st2');
      await notifier.setQuickCode('tiger', replacing: const [], code: st2);
      expect(item('tiger').quickCodes, [st2]);
      expect(notifier.findQuickCode('ST2')?.item.id, 'tiger');

      final wifi = codeForPassword('ST2', 'wifi password: n0tGuessable');
      await expectLater(
          notifier.setQuickCode('wifi', replacing: const [], code: wifi),
          throwsStateError);
      expect(item('wifi').quickCodes, isEmpty);

      // Changing the code of a field replaces it.
      final tiger = QuickCode(code: 't', start: st2.start, end: st2.end);
      await notifier.setQuickCode('tiger', replacing: [st2], code: tiger);
      expect(item('tiger').quickCodes, [tiger]);
      expect(notifier.findQuickCode('st2'), isNull);

      // Now ST2 is free for the other note.
      await notifier.setQuickCode('wifi', replacing: const [], code: wifi);
      expect(item('wifi').quickCodes, [wifi]);

      await notifier.setQuickCode('tiger', replacing: [tiger]);
      expect(item('tiger').quickCodes, isEmpty);
    });

    test('undo brings a note back with its codes, unless one was reused',
        () async {
      final st2 = codeForPassword('st2');
      final t = QuickCode(code: 't', start: st2.start, end: st2.end);
      final c = container([
        withCodes(makeItem(note, id: 'tiger'), [st2]),
        withCodes(makeItem('lone: x', id: 'lone', minutesAgo: 5), const []),
      ]);
      final notifier = c.read(pasteListProvider.notifier);

      await notifier.deleteItem('tiger');
      expect(c.read(quickCodeIndexProvider), isEmpty);
      expect((await notifier.undoDelete())!.quickCodes, [st2]);
      expect(c.read(quickCodeIndexProvider).keys, ['st2']);

      // Delete it again with a second code, and give one away meanwhile.
      await notifier.setQuickCode('tiger', replacing: [st2], code: t);
      await notifier.deleteItem('tiger');
      const lone = QuickCode(code: 'T', start: 6, end: 7);
      await notifier.setQuickCode('lone', replacing: const [], code: lone);
      final restored = await notifier.undoDelete();
      expect(restored!.quickCodes, isEmpty);
      expect(c.read(quickCodeIndexProvider)['t']?.item.id, 'lone');
    });

    test('a quick code search brings its note to the top', () async {
      final st2 = codeForPassword('st2');
      final c = container([
        makeItem('st2 is also in this note', id: 'mention'),
        withCodes(makeItem(note, id: 'tiger', minutesAgo: 9), [st2]),
        makeItem('nothing to see', id: 'other', minutesAgo: 1),
      ]);
      List<String> ids() =>
          [for (final item in c.read(filteredPasteListProvider)) item.id];

      c.read(searchQueryProvider.notifier).state = 'St2';
      expect(ids(), ['tiger', 'mention']);
      expect(c.read(quickCodeMatchProvider)?.code, st2);

      c.read(searchQueryProvider.notifier).state = 'st';
      expect(ids(), ['mention']);
      expect(c.read(quickCodeMatchProvider), isNull);
    });
  });

  group('home screen', () {
    testWidgets('right-click a chip to give it a code, shown on the chip',
        (tester) async {
      final app = TestApp(items: [makeItem(note, id: 'tiger')]);
      await app.pump(tester);

      await tester.tap(passwordChip, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Quick code for Password'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('quickCode')), 'st2');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(app.items.single.quickCodes, [codeForPassword('st2')]);
      expect(app.store.getAll().single.quickCodes, [codeForPassword('st2')],
          reason: 'saved, not only shown');
      expect(chipWhere((c) => c.quickCode == 'st2'), findsOneWidget);
      expect(
          find.text(
              'Type “st2” in the search bar and press Enter to copy Password'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets(
        'typing a code marks the search green and shows its note, and Enter '
        'copies the field as a secret and hides Pastee', (tester) async {
      final app = TestApp(items: [
        makeItem('banana bread', id: 'banana'),
        withCodes(makeItem(note, id: 'tiger', minutesAgo: 30),
            [codeForPassword('st2')]),
      ]);
      await app.pump(tester);
      app.bridge.summon(shown: true);
      await tester.pump();

      expect(find.byIcon(Icons.key_rounded), findsNothing);
      await tester.enterText(searchField, 'ST2');
      await tester.pump();

      // No debounce for a code, and its note is on top even though "st2"
      // appears nowhere in it.
      expect(find.byIcon(Icons.key_rounded), findsOneWidget);
      final tiles = tester.widgetList<PasteTile>(find.byType(PasteTile));
      expect([for (final t in tiles) t.item.id], ['tiger']);
      expect(chipWhere((c) => c.highlighted), findsOneWidget);
      expect(passwordChip, findsOneWidget);
      expect(tester.widget<FieldChip>(passwordChip).highlighted, isTrue);

      await pressEnter(tester);
      await tester.pump();
      expect(app.clipboard.text, 'hunter2!');
      expect(app.clipboard.lastSecret, isTrue);
      expect(app.bridge.hideCalls, 1, reason: 'back to the previous app');
      expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('it hides Pastee even when opened from the Dock or taskbar',
        (tester) async {
      final app = TestApp(items: [
        withCodes(makeItem(note, id: 'tiger'), [codeForPassword('s')]),
      ]);
      await app.pump(tester);

      await tester.enterText(searchField, 's');
      await tester.pump();
      await pressEnter(tester);
      await tester.pump();
      expect(app.clipboard.text, 'hunter2!');
      expect(app.bridge.hideCalls, 1);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a search that is no code works as before', (tester) async {
      final app = TestApp(items: [
        makeItem('banana bread', id: 'banana'),
        withCodes(makeItem(note, id: 'tiger', minutesAgo: 30),
            [codeForPassword('st2')]),
      ]);
      await app.pump(tester);

      await typeInSearch(tester, 'st');
      expect(find.byIcon(Icons.key_rounded), findsNothing);
      expect(find.byType(PasteTile), findsNothing);

      await typeInSearch(tester, 'banana');
      await pressEnter(tester);
      expect(app.clipboard.text, 'banana bread');
      expect(app.clipboard.lastSecret, isFalse);
      expect(app.bridge.hideCalls, 0, reason: 'not summoned');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a code that is taken is refused with where it is used',
        (tester) async {
      const wifi = 'home wifi password: n0tGuessable';
      final app = TestApp(items: [
        makeItem(wifi, id: 'wifi'),
        withCodes(makeItem(note, id: 'tiger', minutesAgo: 30),
            [codeForPassword('st2')]),
      ]);
      await app.pump(tester);

      await tester.tap(
          chipWhere(
              (c) => c.text.startsWith('Password') && c.quickCode == null),
          buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('quickCode')), 'St2');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('already copies a field of'), findsOneWidget);
      expect(app.items.firstWhere((i) => i.id == 'wifi').quickCodes, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.items.firstWhere((i) => i.id == 'wifi').quickCodes, isEmpty);
    });

    testWidgets('the dialog can remove a code', (tester) async {
      final app = TestApp(items: [
        withCodes(makeItem(note, id: 'tiger'), [codeForPassword('st2')]),
      ]);
      await app.pump(tester);

      await tester.tap(passwordChip, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('quickCode')))
              .controller!
              .text,
          'st2');
      await tester.tap(find.text('Remove code'));
      await tester.pumpAndSettle();
      expect(app.items.single.quickCodes, isEmpty);
      expect(chipWhere((c) => c.quickCode != null), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a code whose field is gone copies nothing and says why',
        (tester) async {
      final app = TestApp(items: [
        withCodes(makeItem(note, id: 'tiger'),
            const [QuickCode(code: 'gone', start: 12, end: 16)]),
      ]);
      await app.pump(tester);

      await tester.enterText(searchField, 'gone');
      await tester.pump();
      final icon = tester.widget<Icon>(find.byIcon(Icons.key_rounded));
      final context = tester.element(find.byIcon(Icons.key_rounded));
      expect(icon.color, Theme.of(context).colorScheme.error);

      await pressEnter(tester);
      await tester.pump();
      expect(app.clipboard.text, isNull);
      expect(app.bridge.hideCalls, 0);
      expect(find.textContaining('no longer finds the field'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 750)); // slides in
      await tester.tap(find.text('Remove code'));
      await tester.pump();
      expect(app.items.single.quickCodes, isEmpty);
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
