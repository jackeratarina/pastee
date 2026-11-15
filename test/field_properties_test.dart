import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/model/field_config.dart';
import 'package:pastee/services/field_extractor.dart';
import 'package:pastee/services/masking.dart';
import 'package:pastee/services/paste_titles.dart';

import 'support/field_helpers.dart';

/// Pieces random notes are made of: labels, values, accents, emoji, broken
/// surrogates, separators and line breaks.
final _pieces = [
  'Mật khẩu',
  'mat khau',
  'MÃ ĐƠN',
  'ma don',
  'Member ID',
  'member  id',
  'PIN',
  'pin code',
  'password',
  'user',
  'email',
  'Seat',
  'Locker',
  'id',
  'ref',
  'hunter2!',
  'Abc@12345',
  'K7Q9X',
  'TV-0042',
  'KH-1234',
  '4242 4242 4242 4242',
  '482913',
  '2024',
  'a@b.co',
  'https://x.example.com/?id=42',
  '10.0.0.1',
  '0912 345 678',
  'Order #12345678',
  'ghp_${'a' * 36}',
  ':',
  ': ',
  ' = ',
  ' - ',
  ' – ',
  ' → ',
  ' | ',
  '：',
  '\t',
  ' ',
  '  ',
  ',',
  '\n',
  '\n',
  '\r\n',
  '\n\n',
  'é',
  'ậ',
  'ậ',
  '́',
  'Đ',
  'đ',
  'ﬁ',
  '🎉',
  '👩‍👩‍👧',
  '\uD83D',
  '\uDE00',
  '•',
  '…',
  '(',
  ')',
  '"',
  "'",
  'x',
  '42',
];

String _note(Random random) {
  final length = random.nextInt(40);
  return [
    for (var i = 0; i < length; i++) _pieces[random.nextInt(_pieces.length)]
  ].join();
}

final _configs = [
  configWith([
    rule('Password', phrases: ['mat khau'], secret: true, number: 2),
    rule('Order', phrases: ['mã đơn', 'order'], number: 2),
    rule('Member', phrases: ['member id'], pattern: r'[A-Z]{2}-\d+', number: 9),
    rule('Locker',
        phrases: ['locker'], pattern: r'([A-Z0-9]{5})', secret: true),
    rule('Customer', pattern: r'KH-(\d+)', number: 1),
    rule('Echo', pattern: r'(\d)\1', secret: true),
    rule('Id', phrases: ['id', 'ref']),
  ]),
  configWith(
    [
      rule('Seat', phrases: ['seat', '#'], number: 5)
    ],
    builtIn: {
      for (final field in BuiltInField.values)
        field: BuiltInFieldSetting(
            enabled: field.index.isEven, number: field.index % 9 + 1),
    },
    numberLines: false,
  ),
  configWith([], builtIn: {
    for (final field in BuiltInField.values)
      field: const BuiltInFieldSetting(enabled: false),
  }),
];

bool _covered(List<Span> spans, int start, int end) {
  // Every character of [start, end) is inside some span.
  for (var i = start; i < end; i++) {
    if (!spans.any((s) => s.start <= i && i < s.end)) return false;
  }
  return true;
}

void main() {
  test('random notes: no crashes, valid numbers, never less masking', () {
    final random = Random(20261115);
    var custom = 0, secret = 0, pinned = 0;
    for (var n = 0; n < 1500; n++) {
      final content = _note(random);
      final normal = FieldExtractor.extract(content);
      for (final config in _configs) {
        final e = run(content, config);
        final reason = '${content.runes.toList()} with config '
            '${_configs.indexOf(config)}';

        final numbers = [for (final f in e.fields) f.number];
        expect(numbers.toSet().length, numbers.length, reason: reason);
        expect(numbers, everyElement(inInclusiveRange(1, 9)), reason: reason);
        expect([...numbers]..sort(), numbers, reason: reason);

        for (final f in e.fields) {
          expect(f.span.start, greaterThanOrEqualTo(0), reason: reason);
          expect(f.span.end, lessThanOrEqualTo(content.length), reason: reason);
          if (f.kind == FieldKind.custom) custom++;
          if (f.kind == FieldKind.custom && f.number == 9) pinned++;
          if (f.kind == FieldKind.custom && f.secret) {
            secret++;
            expect(_covered(e.secretSpans, f.span.start, f.span.end), isTrue,
                reason: '$reason: ${f.label} "${f.value}" not masked');
          }
        }

        // Settings only ever add masking.
        for (final s in normal.secretSpans) {
          expect(_covered(e.secretSpans, s.start, s.end), isTrue,
              reason: reason);
        }
        expect(e.secretValues.containsAll(normal.secretValues), isTrue,
            reason: reason);
        if (config.custom.isEmpty) {
          expect(e.secretSpans, normal.secretSpans, reason: reason);
        }

        // Drawing it never throws either.
        Masker.segments(content, e.secretSpans);
        autoTitle(content, config: config);
      }
    }
    // The notes really exercised your own fields.
    expect(custom, greaterThan(1000));
    expect(secret, greaterThan(300));
    expect(pinned, greaterThan(20));
  });
}
