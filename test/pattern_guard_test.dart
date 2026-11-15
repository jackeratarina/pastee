import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/services/pattern_guard.dart';

void main() {
  group('quick checks', () {
    test('good patterns pass', () {
      for (final pattern in [
        r'[A-Z]{2}\d{6}',
        r'KH-\d+',
        r'\p{Lu}+-\d+',
        r'ID-(\d+)',
        r'AB\-\d+', // only valid without Unicode mode, which is tried next
      ]) {
        expect(PatternGuard.quickCheck(pattern), isNull, reason: pattern);
      }
    });

    test('at most 300 characters', () {
      expect(PatternGuard.quickCheck('a' * 300), isNull);
      expect(PatternGuard.quickCheck('a' * 301), contains('300'));
    });

    test('invalid patterns say why', () {
      expect(PatternGuard.quickCheck('(unclosed'),
          'This isn’t a valid pattern: unterminated group.');
      expect(PatternGuard.quickCheck('[z-a]'), contains('valid pattern'));
    });

    test('patterns that can match an empty value are rejected', () {
      for (final pattern in [r'\d*', '^', r'\b', '(?=x)', 'a|', r'(\s)?']) {
        expect(PatternGuard.quickCheck(pattern), contains('empty'),
            reason: pattern);
      }
    });
  });

  group('speed check (background isolate, 250 ms)', () {
    test('ordinary patterns are fast enough', () async {
      for (final pattern in [
        r'[A-Z]{2}\d{6}',
        r'\d{6,}',
        r'KH-(\d+)',
        r'\w+'
      ]) {
        expect(await PatternGuard.checkSpeed(pattern), isNull, reason: pattern);
      }
    });

    test('a pattern that is only slow on pathological lines still passes',
        () async {
      // These backtrack on a long run of letters (quadratic), but on the
      // longest line Pastee would give them that is a few dozen ms.
      for (final pattern in [r'[A-Za-z]+\d+', r'\S+@\S+']) {
        expect(await PatternGuard.checkSpeed(pattern), isNull, reason: pattern);
      }
    });

    test('runaway patterns are rejected and stopped', () async {
      for (final pattern in [
        r'(a+)+$',
        r'(\w+\s?)+$',
        r'\w*\w*\w*!',
        r'(\d+)+$',
        r'(a|aa)+$',
      ]) {
        final watch = Stopwatch()..start();
        expect(await PatternGuard.checkSpeed(pattern), PatternGuard.tooSlow,
            reason: pattern);
        // The budget, plus starting the isolate: it doesn't wait for the
        // pattern to finish (it never would).
        expect(watch.elapsedMilliseconds, lessThan(3000), reason: pattern);
      }
    });

    test('check runs the quick checks first', () async {
      expect(await PatternGuard.check('(unclosed'), contains('valid pattern'));
      expect(await PatternGuard.check(r'\d*'), contains('empty'));
      expect(await PatternGuard.check(r'(a+)+$'), PatternGuard.tooSlow);
      expect(await PatternGuard.check(r'[A-Z]{2}\d{6}'), isNull);
    });
  });

  test('hard inputs are as long as the longest line a pattern sees', () {
    for (final input in PatternGuard.hardInputs()) {
      expect(input.length, lessThanOrEqualTo(PatternGuard.maxLineLength));
      expect(input.length, greaterThan(PatternGuard.maxLineLength - 3));
    }
  });
}
