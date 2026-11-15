/// Finds the values of "Your phrases" (Settings → Fields & numbers) in a note.
///
/// Pure Dart, no Flutter imports.
library;

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../model/field_config.dart';
import 'pattern_guard.dart';

/// A value one of your rules found.
final class CustomMatch {
  const CustomMatch({
    required this.ruleIndex,
    required this.rule,
    required this.value,
    required this.start,
    required this.end,
    required this.labelStart,
    required this.labelEnd,
    this.alsoMask = const [],
  });

  /// Where [rule] is in the config's list. Earlier rules win ties.
  final int ruleIndex;
  final CustomFieldRule rule;
  final String value;

  /// Where [value] is in the text: `[start, end)`.
  final int start;
  final int end;

  /// Where the phrase that found it is (the value itself for a pattern
  /// without phrases). A line holding only that isn't offered as a field.
  final int labelStart;
  final int labelEnd;

  /// More ranges to mask when [rule] is secret. Dart doesn't say where a
  /// capture group matched, so when the group's text occurs more than once
  /// on the line, every place it could be is masked.
  final List<(int, int)> alsoMask;

  @override
  String toString() => 'CustomMatch(${rule.name}, "$value", $start–$end)';
}

class CustomFields {
  CustomFields._();

  /// Lines longer than this are skipped (patterns are only checked against
  /// lines this long).
  static const int maxLineLength = PatternGuard.maxLineLength;

  // Between a phrase and its value: spaces, then optionally a separator.
  static final _separator = RegExp(r'[^\S\n]*(?:[:=\-–—→>|：]+[^\S\n]*)?');
  static final _cellBreak = RegExp(r'\t| \| | \|\| ');
  static final _trailingComma = RegExp(r'[\s,;]+$');
  static final _looksLikeKeyValue =
      RegExp(r'^\s*[\p{L}][\p{L}\p{N} ._-]{0,30}[:：=]\s', unicode: true);

  /// Every value that [rules] find in [text], in reading order. Disabled
  /// rules, and rules whose pattern Pastee won't run, find nothing.
  ///
  /// [text] has `\n` line breaks only (no `\r`). [stops] (sorted) are where
  /// other labels start, like the "PIN" in "Member ID: 12345, PIN: 4821": a
  /// value on the same line ends before them. A phrase inside one of
  /// [notLabels] (sorted, not overlapping: links and email addresses) is
  /// ignored.
  static List<CustomMatch> find(String text, List<CustomFieldRule> rules,
      {List<int> stops = const [], List<(int, int)> notLabels = const []}) {
    final phraseRules = <(int, CustomFieldRule, RegExp?)>[];
    final patternRules = <(int, CustomFieldRule, RegExp)>[];
    for (var i = 0; i < rules.length; i++) {
      final rule = rules[i];
      if (!rule.enabled) continue;
      final re = rule.hasPattern ? PatternGuard.compile(rule.pattern) : null;
      if (rule.hasPattern && re == null) continue;
      if (rule.phrases.isNotEmpty) {
        phraseRules.add((i, rule, re));
      } else if (re != null) {
        patternRules.add((i, rule, re));
      }
    }
    if (phraseRules.isEmpty && patternRules.isEmpty) return const [];

    final lines = _lines(text);
    final matches = <CustomMatch>[
      if (phraseRules.isNotEmpty)
        ..._byPhrase(text, lines, phraseRules, stops, notLabels),
      for (final (index, rule, re) in patternRules)
        ..._byPattern(text, lines, index, rule, re),
    ];
    matches.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.ruleIndex.compareTo(b.ruleIndex);
    });
    return matches;
  }

  // ── phrases ──────────────────────────────────────────────────────────────

  static List<CustomMatch> _byPhrase(
      String text,
      List<(int, int)> lines,
      List<(int, CustomFieldRule, RegExp?)> rules,
      List<int> stops,
      List<(int, int)> notLabels) {
    final folded = FoldedText.of(text);
    final hay = folded.text;
    final found = <_Phrase>[];
    for (final (index, rule, re) in rules) {
      for (final raw in rule.phrases) {
        final phrase = FoldedText.of(raw).text.trim();
        if (phrase.isEmpty) continue;
        final wordStart = FoldedText.isWordCharAt(phrase, 0);
        final wordEnd = FoldedText.isWordCharBefore(phrase, phrase.length);
        var from = 0;
        while (true) {
          final at = hay.indexOf(phrase, from);
          if (at < 0) break;
          from = at + 1;
          final end = at + phrase.length;
          // Whole words only: "pin" is not in "spin" or "pinned".
          if (wordStart && FoldedText.isWordCharBefore(hay, at)) continue;
          if (wordEnd && FoldedText.isWordCharAt(hay, end)) continue;
          final start = folded.original(at);
          if (isInside(notLabels, start)) continue;
          found.add(_Phrase(index, rule, re, start, folded.original(end),
              _lineOf(lines, start)));
        }
      }
    }
    if (found.isEmpty) return const [];
    // Longest phrase first where two overlap ("PIN code" before "PIN"), then
    // the rule listed first.
    found.sort((a, b) {
      if (a.start != b.start) return a.start.compareTo(b.start);
      if (a.end != b.end) return b.end.compareTo(a.end);
      return a.ruleIndex.compareTo(b.ruleIndex);
    });
    final starts = [for (final p in found) p.start];

    final matches = <CustomMatch>[];
    var claimedEnd = -1;
    for (final phrase in found) {
      // Part of a phrase that already gave a value.
      if (phrase.start < claimedEnd) continue;
      final (lineStart, lineEnd) = lines[phrase.line];
      if (lineEnd - lineStart > maxLineLength) continue;
      final region = _valueRegion(text, lines, phrase, starts, stops);
      if (region == null) continue;
      final value = _valueIn(text, region.$1, region.$2, phrase.re);
      if (value == null) continue;
      claimedEnd = phrase.end;
      matches.add(CustomMatch(
        ruleIndex: phrase.ruleIndex,
        rule: phrase.rule,
        value: value.$1,
        start: value.$2,
        end: value.$3,
        labelStart: phrase.start,
        labelEnd: phrase.end,
        alsoMask: value.$4,
      ));
    }
    return matches;
  }

  /// The text a phrase's value is taken from: the rest of its line after an
  /// optional separator, up to the next phrase, label or table cell; or, if
  /// nothing follows the phrase, the next non-empty line.
  static (int, int)? _valueRegion(String text, List<(int, int)> lines,
      _Phrase phrase, List<int> phraseStarts, List<int> stops) {
    final (_, lineEnd) = lines[phrase.line];
    final from = _separator.matchAsPrefix(text, phrase.end)?.end ?? phrase.end;
    var cut = lineEnd;
    var wasCut = false;
    for (final next in [
      _firstAtOrAfter(phraseStarts, from),
      _firstAtOrAfter(stops, from),
    ]) {
      if (next != null && next < cut) {
        cut = next;
        wasCut = true;
      }
    }
    final cell = text.substring(from, cut).indexOf(_cellBreak);
    if (cell >= 0) {
      cut = from + cell;
      wasCut = true;
    }
    var (start, end) = _trimmed(text, from, cut);
    if (wasCut && end > start) {
      // "Member ID: 123, PIN: 4821": the comma belongs to the sentence.
      final tail = _trailingComma.firstMatch(text.substring(start, end));
      if (tail != null) end = start + tail.start;
    }
    if (end > start) return (start, end);
    if (wasCut) return null; // another label follows straight away

    for (var i = phrase.line + 1; i < lines.length; i++) {
      final (s, e) = lines[i];
      final (start, end) = _trimmed(text, s, e);
      if (start == end) continue;
      if (e - s > maxLineLength) return null;
      // That line has a label of its own.
      if (_firstAtOrAfter(phraseStarts, start) == start ||
          _firstAtOrAfter(stops, start) == start ||
          _looksLikeKeyValue.hasMatch(text.substring(s, e))) {
        return null;
      }
      return (start, end);
    }
    return null;
  }

  /// The value in `text[start, end)`: all of it, or the first match of [re]
  /// (its group 1 if it has one).
  static (String, int, int, List<(int, int)>)? _valueIn(
      String text, int start, int end, RegExp? re) {
    final subject = text.substring(start, end);
    if (re == null) return (subject, start, end, const []);
    for (final m in re.allMatches(subject)) {
      final value = _valueOfMatch(m, subject);
      if (value == null) continue;
      return (
        value.$1,
        start + value.$2,
        start + value.$3,
        [for (final (s, e) in value.$4) (start + s, start + e)],
      );
    }
    return null;
  }

  // ── patterns on their own ────────────────────────────────────────────────

  static List<CustomMatch> _byPattern(String text, List<(int, int)> lines,
      int index, CustomFieldRule rule, RegExp re) {
    final matches = <CustomMatch>[];
    for (final (lineStart, lineEnd) in lines) {
      if (lineEnd == lineStart || lineEnd - lineStart > maxLineLength) {
        continue;
      }
      final line = text.substring(lineStart, lineEnd);
      for (final m in re.allMatches(line)) {
        final value = _valueOfMatch(m, line);
        if (value == null) continue;
        matches.add(CustomMatch(
          ruleIndex: index,
          rule: rule,
          value: value.$1,
          start: lineStart + value.$2,
          end: lineStart + value.$3,
          labelStart: lineStart + value.$2,
          labelEnd: lineStart + value.$3,
          alsoMask: [
            for (final (s, e) in value.$4) (lineStart + s, lineStart + e)
          ],
        ));
      }
    }
    return matches;
  }

  /// What a match copies (group 1 if the pattern has groups) and where it
  /// is in [subject], plus every other place it might be.
  static (String, int, int, List<(int, int)>)? _valueOfMatch(
      RegExpMatch m, String subject) {
    if (m.groupCount == 0) {
      if (m.end == m.start) return null;
      return (m.group(0)!, m.start, m.end, const []);
    }
    final group = m.group(1);
    if (group == null || group.isEmpty) return null;
    final places = <int>[];
    for (var at = subject.indexOf(group);
        at >= 0;
        at = subject.indexOf(group, at + 1)) {
      places.add(at);
    }
    if (places.length == 1) {
      return (group, places.first, places.first + group.length, const []);
    }
    // Most likely inside the whole match; mask every candidate to be sure.
    final inside = places.firstWhere(
        (at) => at >= m.start && at + group.length <= m.end,
        orElse: () => places.first);
    return (
      group,
      inside,
      inside + group.length,
      [
        for (final at in places) (at, at + group.length),
        if (m.end > m.start) (m.start, m.end),
      ],
    );
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static List<(int, int)> _lines(String text) {
    final result = <(int, int)>[];
    var start = 0;
    while (true) {
      final end = text.indexOf('\n', start);
      if (end < 0) {
        result.add((start, text.length));
        return result;
      }
      result.add((start, end));
      start = end + 1;
    }
  }

  /// Whether [offset] is inside one of the sorted, non-overlapping [ranges].
  static bool isInside(List<(int, int)> ranges, int offset) {
    var low = 0, high = ranges.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (ranges[mid].$2 <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low < ranges.length && ranges[low].$1 <= offset;
  }

  /// The index of the line that contains [offset].
  static int _lineOf(List<(int, int)> lines, int offset) {
    var low = 0, high = lines.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (lines[mid].$1 <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// The first of the sorted [values] that is at least [from].
  static int? _firstAtOrAfter(List<int> values, int from) {
    var low = 0, high = values.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (values[mid] < from) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low < values.length ? values[low] : null;
  }

  static (int, int) _trimmed(String text, int start, int end) {
    final slice = text.substring(start, end);
    final lead = slice.length - slice.trimLeft().length;
    final trail = slice.length - slice.trimRight().length;
    return lead == slice.length ? (start, start) : (start + lead, end - trail);
  }
}

final class _Phrase {
  _Phrase(this.ruleIndex, this.rule, this.re, this.start, this.end, this.line);

  final int ruleIndex;
  final CustomFieldRule rule;
  final RegExp? re;
  final int start;
  final int end;
  final int line;
}

/// Text folded for matching phrases: lower case, without accents (đ is d),
/// runs of spaces made one, and line breaks kept. It remembers where each
/// character came from, so a match maps back to the original.
final class FoldedText {
  FoldedText._(this.text, this._source, this._length);

  factory FoldedText.of(String original) {
    final out = StringBuffer();
    final source = <int>[];
    var inSpace = false;
    var i = 0;
    while (i < original.length) {
      final unit = original.codeUnitAt(i);
      var codePoint = unit;
      var width = 1;
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < original.length) {
        final low = original.codeUnitAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          codePoint = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
          width = 2;
        }
      }
      if (codePoint == 0x0A) {
        out.writeCharCode(0x0A);
        source.add(i);
        inSpace = false;
      } else if (_isSpace(codePoint)) {
        if (!inSpace) {
          out.writeCharCode(0x20);
          source.add(i);
          inSpace = true;
        }
      } else if (codePoint < 0x80) {
        out.writeCharCode(codePoint >= 0x41 && codePoint <= 0x5A
            ? codePoint + 32
            : codePoint);
        source.add(i);
        inSpace = false;
      } else {
        final folded = _fold(codePoint);
        if (folded.isNotEmpty) {
          out.write(folded);
          for (var k = 0; k < folded.length; k++) {
            source.add(i);
          }
          inSpace = false;
        }
      }
      i += width;
    }
    return FoldedText._(out.toString(), source, original.length);
  }

  final String text;
  final List<int> _source;
  final int _length;

  /// The offset in the original text of offset [index] in [text]. The end of
  /// [text] maps to the end of the original.
  int original(int index) => index < _source.length ? _source[index] : _length;

  static final _marks = RegExp(r'\p{M}', unicode: true);
  static const _letters = {'đ': 'd', 'ł': 'l', 'ø': 'o', 'ı': 'i', 'ħ': 'h'};
  static final _cache = <int, String>{};

  /// One non-ASCII character, folded: "Ậ" → "a", "Đ" → "d", "ﬁ" → "fi", and
  /// a combining accent on its own → "".
  static String _fold(int codePoint) {
    final cached = _cache[codePoint];
    if (cached != null) return cached;
    var s = String.fromCharCode(codePoint).toLowerCase();
    s = unorm.nfkd(s).replaceAll(_marks, '').toLowerCase();
    if (s.length == 1) s = _letters[s] ?? s;
    if (_cache.length < 4096) _cache[codePoint] = s;
    return s;
  }

  static bool _isSpace(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0B ||
      c == 0x0C ||
      c == 0x0D ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000 ||
      c == 0xFEFF;

  static final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

  /// Whether the character starting at [index] is a letter, digit or _.
  static bool isWordCharAt(String s, int index) {
    if (index < 0 || index >= s.length) return false;
    final unit = s.codeUnitAt(index);
    if (unit < 0x80) return _asciiWord(unit);
    final end = unit >= 0xD800 && unit <= 0xDBFF && index + 1 < s.length
        ? index + 2
        : index + 1;
    return _wordChar.hasMatch(s.substring(index, end));
  }

  /// Whether the character that ends at [index] is a letter, digit or _.
  static bool isWordCharBefore(String s, int index) {
    if (index <= 0 || index > s.length) return false;
    final unit = s.codeUnitAt(index - 1);
    if (unit < 0x80) return _asciiWord(unit);
    final start =
        unit >= 0xDC00 && unit <= 0xDFFF && index >= 2 ? index - 2 : index - 1;
    return _wordChar.hasMatch(s.substring(start, index));
  }

  static bool _asciiWord(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F;
}
