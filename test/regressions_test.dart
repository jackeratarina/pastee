import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/paste_item.dart';

import 'support/fakes.dart';

final mac = TargetPlatformVariant.only(TargetPlatform.macOS);

List<String> editors(WidgetTester t) => t
    .widgetList<EditableText>(find.byType(EditableText))
    .map((e) => e.controller.text)
    .toList();

void main() {
  testWidgets('first Cmd+E opens the editor, no exception', (tester) async {
    final app = TestApp(items: [makeItem('some note', id: 'n')]);
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(editors(tester), contains('some note'));
  }, variant: mac);

  testWidgets('hidden item: editor starts empty, Escape keeps the title',
      (tester) async {
    final typed = PasteItem(
        id: 't',
        title: 'Bank 482913',
        content: 'pin: 482913',
        createdAt: DateTime.now());
    final app = TestApp(items: [typed]);
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(editors(tester).any((t) => t.contains('482913')), isFalse);
    expect(find.text('Bank ••••••••'), findsOneWidget); // the hint
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(app.items.single.title, 'Bank 482913');
  }, variant: mac);

  testWidgets('sensitive item: no Key text in chips, tooltips or snackbar',
      (tester) async {
    final app = TestApp(items: [
      makeItem('Dr. Smith oncology: biopsy on Friday', id: 's', sensitive: true)
    ]);
    await app.pump(tester);
    expect(find.textContaining('Dr. Smith'), findsNothing);
    expect(find.byTooltip('⌘1  Field (hidden)'), findsOneWidget);
    await pressShortcut(tester, LogicalKeyboardKey.digit1);
    await tester.pump();
    expect(find.text('Copied Field'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('Enter right after typing copies the filtered top item',
      (tester) async {
    final app = TestApp(items: [
      makeItem('Slack: team chat notes', id: 'top'),
      makeItem('bank\npassword: Tr0ub4dor&3', id: 'bank', minutesAgo: 5),
    ]);
    await app.pump(tester);
    await tester.enterText(find.byType(TextField), 'bank');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(app.clipboard.text, 'bank\npassword: Tr0ub4dor&3');
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);

  testWidgets('first copy flashes', (tester) async {
    final app = TestApp(items: [makeItem('flash me', id: 'f')]);
    await app.pump(tester);
    await pressShortcut(tester, LogicalKeyboardKey.keyC);
    await tester.pump(const Duration(milliseconds: 50));
    final yellow = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where((d) =>
            d.decoration is BoxDecoration &&
            (d.decoration as BoxDecoration).color != null &&
            (d.decoration as BoxDecoration).color!.b < 0.3 &&
            (d.decoration as BoxDecoration).color!.r > 0.9)
        .length;
    expect(yellow, 1);
    await tester.pump(const Duration(seconds: 2));
  }, variant: mac);
}
