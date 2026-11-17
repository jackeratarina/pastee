import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// A short code that copies one field of a note: type it in the search bar
/// and press Enter.
///
/// A code is a shortcut, not a secret. App Lock is what keeps the notes
/// private, so a code can be as short as one character.
@immutable
class QuickCode {
  const QuickCode({required this.code, required this.start, required this.end});

  /// Longest code, in characters.
  static const maxLength = 32;

  /// As the user typed it. Matching ignores case.
  final String code;

  /// Where the field's value sits in the note. A note's content never
  /// changes, so this keeps pointing at the same text even when the Fields &
  /// numbers settings change what Pastee detects around it.
  final int start;
  final int end;

  /// What the search text must equal, after [normalize], to use this code.
  String get key => normalize(code);

  /// Ignores case and surrounding spaces, and treats the precomposed and
  /// combining forms of an accented letter alike (Vietnamese keyboards can
  /// type either).
  static String normalize(String text) => unorm.nfc(text.trim()).toLowerCase();

  /// Why [input] can't be a code, or null if it can. Whether another field
  /// already uses it is checked separately.
  static String? problemWith(String input) {
    final code = input.trim();
    if (code.isEmpty) return 'Type at least one character';
    if (code.contains(RegExp(r'\s'))) return 'Leave out spaces';
    if (code.characters.length > maxLength) {
      return 'Use at most $maxLength characters';
    }
    return null;
  }

  bool hasSpan(int start, int end) => this.start == start && this.end == end;

  Map<String, Object> toJson() => {'c': code, 's': start, 'e': end};

  /// Null for anything that isn't a valid saved code.
  static QuickCode? fromJson(Object? json) {
    if (json is! Map) return null;
    final code = json['c'], start = json['s'], end = json['e'];
    if (code is! String || start is! int || end is! int) return null;
    if (start < 0 || end <= start || problemWith(code) != null) return null;
    return QuickCode(code: code, start: start, end: end);
  }

  @override
  bool operator ==(Object other) =>
      other is QuickCode &&
      other.code == code &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(code, start, end);

  @override
  String toString() => 'QuickCode($code, $start–$end)';
}
