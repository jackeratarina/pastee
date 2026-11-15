/// Checks the value patterns typed into "Your phrases", so a typo or a
/// pattern that takes forever on some text can't freeze Pastee.
///
/// Fields are found on the UI thread, so a pattern that backtracks without
/// end (`(a+)+$` on a long line of a's) would hang the app. Patterns are only
/// saved after they pass [check], and at run time they only ever see one line
/// of at most [maxLineLength] characters.
library;

import 'dart:async';
import 'dart:isolate';

class PatternGuard {
  PatternGuard._();

  static const int maxLength = 300;

  /// Lines longer than this are skipped by your own fields, so a pattern
  /// never runs on more text than this at once.
  static const int maxLineLength = 2000;

  /// How long a pattern may take on each of [hardInputs].
  ///
  /// Per input rather than in total: ordinary patterns such as `\S+@\S+`
  /// backtrack a little on a 2,000-letter line (tens of ms), and should pass
  /// on any machine, while runaway ones take seconds or never finish.
  static const Duration budget = Duration(milliseconds: 250);

  static const tooSlow = 'This pattern takes too long on some text. '
      'Avoid repeats inside repeats, like (a+)+, '
      'or give a repeat a limit, like {1,30}.';
  static const couldNotCheck = 'Couldn’t check this pattern. Try again.';

  static final _compiled = <String, RegExp?>{};

  /// [pattern] compiled the way Pastee runs it, or null if Pastee won't run
  /// it (empty, too long or invalid).
  ///
  /// Unicode mode comes first, so `\p{L}` means "any letter". Patterns that
  /// are only valid without it (`\-` outside brackets, say) still work.
  static RegExp? compile(String pattern) {
    if (_compiled.containsKey(pattern)) return _compiled[pattern];
    final re = _compile(pattern);
    if (_compiled.length >= 64) _compiled.remove(_compiled.keys.first);
    return _compiled[pattern] = re;
  }

  static RegExp? _compile(String pattern) {
    if (pattern.isEmpty || pattern.length > maxLength) return null;
    try {
      return RegExp(pattern, unicode: true);
    } on FormatException {
      // Try again below.
    }
    try {
      return RegExp(pattern);
    } on FormatException {
      return null;
    }
  }

  /// What is wrong with [pattern] that shows without running it on long text
  /// (too long, invalid, can match an empty value), or null.
  static String? quickCheck(String pattern) {
    if (pattern.length > maxLength) {
      return 'Use at most $maxLength characters.';
    }
    if (compile(pattern) == null) {
      String? reason;
      try {
        RegExp(pattern, unicode: true);
      } on FormatException catch (error) {
        reason = _reason(error.message);
      }
      return reason == null
          ? 'This isn’t a valid pattern.'
          : 'This isn’t a valid pattern: $reason.';
    }
    if (_matchesEmpty(compile(pattern)!)) {
      return 'This pattern can match an empty value. Make it match at least '
          'one character, with + instead of *, for example.';
    }
    return null;
  }

  /// "Invalid regular expression: /(/: Unterminated group" → "unterminated group".
  static String? _reason(String message) {
    final last = message.split(':').last.trim();
    if (last.isEmpty) return null;
    return last[0].toLowerCase() + last.substring(1);
  }

  static bool _matchesEmpty(RegExp re) {
    for (final probe in const ['', 'a', 'A1', ' ', '-', 'ab 12', 'x\ty']) {
      for (final m in re.allMatches(probe)) {
        if (m.end == m.start) return true;
      }
    }
    return false;
  }

  /// Text that slow patterns choke on: long runs of letters and digits, and
  /// alternating characters and words, each as long as the longest line a
  /// pattern ever sees.
  static List<String> hardInputs() {
    const n = maxLineLength - 1;
    return [
      '${'a' * n}!',
      '${'A1' * (n ~/ 2)}!',
      '${'1' * n}x',
      '${'a ' * (n ~/ 2)}!',
    ];
  }

  /// Runs [pattern] over [hardInputs] in a background isolate, giving it
  /// [budget] for each. Returns [tooSlow] (or why it couldn't check), or null
  /// if the pattern is fast enough.
  ///
  /// The clock starts once the isolate is up, so a slow start doesn't count
  /// against the pattern. A pattern that runs out of time is stopped.
  static Future<String?> checkSpeed(String pattern,
      {Duration budget = PatternGuard.budget}) async {
    final port = ReceivePort();
    final result = Completer<String?>();
    void finish(String? problem) {
      if (!result.isCompleted) result.complete(problem);
    }

    Timer? clock;
    // The isolate never got going (it should start in milliseconds).
    final startup = Timer(const Duration(seconds: 10), () {
      finish(couldNotCheck);
    });
    final subscription = port.listen((message) {
      if (message is int) {
        // Starting on hard input number `message`.
        startup.cancel();
        clock?.cancel();
        clock = Timer(budget, () => finish(tooSlow));
      } else if (message == 'done') {
        finish(null);
      } else {
        // An error in the isolate, or it ended without saying why.
        finish(message == 'invalid' ? quickCheck(pattern) : tooSlow);
      }
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _speedWorker,
        (port.sendPort, pattern),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      return await result.future;
    } catch (_) {
      return couldNotCheck;
    } finally {
      startup.cancel();
      clock?.cancel();
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      port.close();
    }
  }

  static void _speedWorker((SendPort, String) message) {
    final (port, pattern) = message;
    final re = compile(pattern);
    if (re == null) {
      port.send('invalid');
      return;
    }
    final inputs = hardInputs();
    for (var i = 0; i < inputs.length; i++) {
      port.send(i);
      for (final _ in re.allMatches(inputs[i])) {}
    }
    port.send('done');
  }

  /// Everything the rule editor checks before saving a pattern.
  static Future<String?> check(String pattern) async =>
      quickCheck(pattern) ?? await checkSpeed(pattern);
}
