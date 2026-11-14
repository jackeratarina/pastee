import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart' as clock_package;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_auth.dart';
import 'passcode.dart';
import 'storage_service.dart';

/// When App Lock locks Pastee again after you've unlocked it.
enum LockTimeout {
  immediately(Duration.zero, 'As soon as Pastee is hidden'),
  oneMinute(Duration(minutes: 1), 'After 1 minute away'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes away'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes away'),
  oneHour(Duration(hours: 1), 'After 1 hour away'),
  onlyAtLaunch(null, 'Only when Pastee starts');

  const LockTimeout(this.duration, this.label);

  /// Null: only when Pastee starts.
  final Duration? duration;
  final String label;
}

@immutable
class AppLockState {
  const AppLockState({
    this.enabled = false,
    this.locked = false,
    this.deviceUnlock = false,
    this.timeout = LockTimeout.fiveMinutes,
    this.failures = 0,
    this.lockedOutUntil,
  });

  /// A passcode is set.
  final bool enabled;

  /// The lock screen is showing.
  final bool locked;

  /// Touch ID / Windows Hello may unlock instead of the passcode.
  final bool deviceUnlock;

  final LockTimeout timeout;

  /// Wrong passcodes in a row.
  final int failures;

  /// No passcode attempts are accepted before this time.
  final DateTime? lockedOutUntil;

  AppLockState copyWith({
    bool? enabled,
    bool? locked,
    bool? deviceUnlock,
    LockTimeout? timeout,
    int? failures,
    DateTime? Function()? lockedOutUntil,
  }) {
    return AppLockState(
      enabled: enabled ?? this.enabled,
      locked: locked ?? this.locked,
      deviceUnlock: deviceUnlock ?? this.deviceUnlock,
      timeout: timeout ?? this.timeout,
      failures: failures ?? this.failures,
      lockedOutUntil:
          lockedOutUntil != null ? lockedOutUntil() : this.lockedOutUntil,
    );
  }
}

enum PasscodeResult { ok, wrong, lockedOut }

/// App Lock: a passcode (and optionally Touch ID / Windows Hello) in front of
/// your items. It keeps people at your computer out of Pastee; the items
/// themselves are already encrypted on disk.
///
/// Pastee locks at launch, on [lock], after [AppLockState.timeout] away from
/// it, and after the same time in front of it without input. The UI reports
/// where Pastee is with [cameBack] and [wentAway], and input with
/// [userActive]. Pastee counts as in front until the first [wentAway].
class AppLockNotifier extends StateNotifier<AppLockState> {
  AppLockNotifier(
    this._store,
    this._device, {
    this.iterations = PasscodeHash.defaultIterations,
    DateTime Function()? clock,
  })  : _clock = clock ?? (() => clock_package.clock.now()),
        super(const AppLockState()) {
    final saved = _store.read(_kPasscode);
    _hash = PasscodeHash.fromJson(saved);
    // A passcode that's there but can't be read (a damaged or edited settings
    // file) keeps Pastee locked: no passcode matches it, so only "Forgot
    // passcode?" ([disable]) gets past it.
    final enabled = saved != null;
    _launchLock = enabled;
    final timeout = _store.read(_kTimeout);
    final failures = _store.read(_kFailures);
    final lockout = _store.read(_kLockedOutUntil);
    state = AppLockState(
      enabled: enabled,
      // Always locked when Pastee starts.
      locked: enabled,
      deviceUnlock: _hash != null && _store.read(_kDeviceUnlock) == true,
      timeout: LockTimeout.values.firstWhere((t) => t.name == timeout,
          orElse: () => LockTimeout.fiveMinutes),
      failures: failures is int && failures > 0 ? failures : 0,
      lockedOutUntil: lockout is int
          ? DateTime.fromMillisecondsSinceEpoch(
              lockout.clamp(-_maxEpochMilliseconds, _maxEpochMilliseconds))
          : null,
    );
    _capLockout();
  }

  static const _kPasscode = 'lock.passcode';
  static const _kDeviceUnlock = 'lock.deviceUnlock';
  static const _kTimeout = 'lock.timeout';
  static const _kFailures = 'lock.failures';
  static const _kLockedOutUntil = 'lock.lockedOutUntil';

  /// Wrong passcodes allowed before a wait: 30 s, then doubling, up to 15 min.
  /// The count is saved, so restarting Pastee doesn't reset it.
  static const freeAttempts = 5;

  /// The longest wait. One that ends later was set while the clock was ahead.
  static const _maxLockout = Duration(minutes: 15);

  /// With [LockTimeout.immediately]: how long Pastee may sit behind other
  /// windows, still visible, before it locks…
  static const _visibleGrace = Duration(seconds: 15);

  /// …and how long it may sit in front without input.
  static const _immediatelyIdle = Duration(minutes: 1);

  static const _maxEpochMilliseconds = 8640000000000000;

  final SettingsStore _store;
  final DeviceAuthenticator _device;
  final int iterations;
  final DateTime Function() _clock;
  PasscodeHash? _hash;
  bool _launchLock = false;

  /// Where Pastee is, as last reported by [cameBack] and [wentAway].
  bool _inFront = true;
  bool _hidden = false;

  /// When Pastee last left the front (wall clock, so time asleep counts).
  DateTime? _awaySince;
  Timer? _awayTimer;

  /// When the idle countdown last started: an unlock, coming back, input.
  DateTime? _activeSince;
  Timer? _idleTimer;

  /// Pastee's own Touch ID / Windows Hello prompts showing right now.
  int _prompts = 0;

  bool _capScheduled = false;
  final _attempts = _Serial();
  final _passcodeWrites = _Serial();

  /// The lock Pastee starts with: true from launch (with App Lock on) until
  /// the first unlock, by passcode or device.
  bool get isLaunchLock => _launchLock && state.enabled;

  /// Time left before passcode attempts are accepted again, or null.
  Duration? get lockoutRemaining {
    final until = state.lockedOutUntil;
    if (until == null) return null;
    var left = until.difference(_clock());
    if (left > _maxLockout) {
      left = _maxLockout;
      // The lock screen asks while it builds, when the state mustn't change,
      // so the saved time is shortened just after.
      if (!_capScheduled) {
        _capScheduled = true;
        scheduleMicrotask(() {
          _capScheduled = false;
          if (mounted) _capLockout();
        });
      }
    }
    return left > Duration.zero ? left : null;
  }

  /// Wrong passcodes left before a wait starts.
  int get attemptsLeft => math.max(0, freeAttempts - state.failures);

  /// Turns App Lock on, or changes the passcode. Doesn't lock or unlock
  /// Pastee: a change that finishes after Pastee locked leaves it locked.
  Future<void> setPasscode(String passcode) {
    return _passcodeWrites.run(() async {
      final hash = await PasscodeHash.create(passcode, iterations: iterations);
      await _store.write(_kPasscode, hash.toJson());
      if (!mounted) return;
      _hash = hash;
      final turningOn = !state.enabled;
      state = state.copyWith(enabled: true);
      if (turningOn) _startCountdowns();
      await _resetFailures();
    });
  }

  /// Turns App Lock off. Callers confirm the passcode first, or erase the
  /// items ("Forgot passcode?").
  Future<void> disable() {
    return _passcodeWrites.run(() async {
      await _store.write(_kPasscode, null);
      await _store.write(_kDeviceUnlock, null);
      await _store.write(_kFailures, null);
      await _store.write(_kLockedOutUntil, null);
      // Only now: if saving failed, App Lock stays on, with its passcode.
      _hash = null;
      _launchLock = false;
      _cancelTimers();
      if (!mounted) return;
      state = state.copyWith(
        enabled: false,
        locked: false,
        deviceUnlock: false,
        failures: 0,
        lockedOutUntil: () => null,
      );
    });
  }

  /// Checks [passcode] without changing the lock, for confirming settings
  /// changes. Wrong attempts count toward the lockout.
  Future<PasscodeResult> checkPasscode(String passcode) async {
    final (result, _) = await _attempts.run(() => _check(passcode));
    return result;
  }

  Future<PasscodeResult> unlockWithPasscode(String passcode) async {
    final (result, matched) = await _attempts.run(() => _check(passcode));
    if (result == PasscodeResult.ok && mounted) {
      _unlock();
      if (matched != null && matched.iterations < iterations) {
        await _strengthen(matched, passcode);
      }
    }
    return result;
  }

  /// Unlocks with Touch ID / Windows Hello, if that's turned on.
  Future<bool> unlockWithDevice() async {
    if (!_deviceUnlockOn) return false;
    final ok = await _prompt('Unlock Pastee');
    if (!ok || !mounted || !_deviceUnlockOn) return false;
    await _resetFailures();
    if (!mounted) return false;
    _unlock();
    return true;
  }

  /// Asks the operating system to confirm it's you, in place of the passcode.
  /// False, without asking, unless App Lock and device unlock are both on.
  Future<bool> confirmWithDevice(String reason) async {
    if (!_deviceUnlockOn) return false;
    return _prompt(reason);
  }

  /// Shows the operating system's prompt whatever the settings, to check it
  /// works before device unlock is turned on. Changes nothing.
  Future<bool> testDevice(String reason) => _prompt(reason);

  Future<void> setDeviceUnlock(bool on) async {
    if (!state.enabled || _hash == null) return;
    state = state.copyWith(deviceUnlock: on);
    await _store.write(_kDeviceUnlock, on);
  }

  Future<void> setTimeout(LockTimeout timeout) async {
    state = state.copyWith(timeout: timeout);
    _cancelTimers();
    _arm();
    await _store.write(_kTimeout, timeout.name);
  }

  void lock() {
    _cancelTimers();
    if (state.enabled && !state.locked) state = state.copyWith(locked: true);
  }

  /// Any key press or pointer input in Pastee. While it's unlocked and in
  /// front, starts the idle countdown again.
  void userActive() {
    if (!_guarding || !_inFront) return;
    final limit = _idleLimit;
    final since = _activeSince;
    if (limit != null && since != null && _clock().difference(since) >= limit) {
      // The countdown should have fired already (the Mac slept, App Nap…).
      lock();
      return;
    }
    _startIdle();
  }

  /// Pastee lost focus ([hidden] false) or was hidden or minimized. Starts the
  /// countdown, so Pastee is already locked when it next appears, and nothing
  /// it showed before flashes on screen.
  void wentAway({required bool hidden}) {
    _inFront = false;
    _hidden = hidden;
    // Pastee's own Touch ID / Windows Hello prompt takes the focus; that
    // isn't going away. Where Pastee ended up is applied after the prompt.
    if (_prompts == 0) _leftFront();
  }

  /// Pastee is in front again.
  void cameBack() {
    _inFront = true;
    _hidden = false;
    if (_prompts == 0) _backInFront();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  // ── where Pastee is ────────────────────────────────────────────────────

  /// App Lock is on and Pastee is unlocked: the countdowns matter.
  bool get _guarding => state.enabled && !state.locked;

  bool get _deviceUnlockOn =>
      state.enabled && state.deviceUnlock && _hash != null;

  /// Time away before Pastee locks; null: never.
  Duration? get _awayLimit => state.timeout == LockTimeout.immediately
      ? (_hidden ? Duration.zero : _visibleGrace)
      : state.timeout.duration;

  /// Time in front without input before Pastee locks; null: never.
  Duration? get _idleLimit => state.timeout == LockTimeout.immediately
      ? _immediatelyIdle
      : state.timeout.duration;

  void _unlock() {
    _launchLock = false;
    if (state.locked) state = state.copyWith(locked: false);
    _startCountdowns();
  }

  /// After an unlock or turning App Lock on: you're here now, so time away
  /// (if Pastee isn't in front, say focus went back to another app after a
  /// system prompt) counts from now.
  void _startCountdowns() {
    _awaySince = _inFront ? null : _clock();
    _cancelTimers();
    _arm();
  }

  /// Starts whichever countdown applies where Pastee is now.
  void _arm() {
    if (_inFront) {
      _cancelAwayTimer();
      _startIdle();
    } else {
      _leftFront();
    }
  }

  void _leftFront() {
    final now = _clock();
    final since = _awaySince ??= now;
    _cancelIdleTimer();
    final limit = _awayLimit;
    if (!_guarding || limit == null) return;
    // Timers stall while the computer sleeps or App Nap holds Pastee back,
    // and the clock can jump: check the time, not just the timer.
    final away = now.difference(since);
    if (away >= limit) {
      lock();
    } else {
      _awayTimer ??= Timer(limit - away, _timedOut);
    }
  }

  void _backInFront() {
    final since = _awaySince;
    final limit = _awayLimit;
    _awaySince = null;
    _cancelAwayTimer();
    if (_guarding &&
        since != null &&
        limit != null &&
        _clock().difference(since) >= limit) {
      lock();
      return;
    }
    _startIdle();
  }

  void _startIdle() {
    _cancelIdleTimer();
    final limit = _idleLimit;
    if (!_guarding || !_inFront || limit == null) return;
    _activeSince = _clock();
    _idleTimer = Timer(limit, _timedOut);
  }

  void _timedOut() {
    if (mounted) lock();
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeSince = null;
  }

  void _cancelAwayTimer() {
    _awayTimer?.cancel();
    _awayTimer = null;
  }

  void _cancelTimers() {
    _cancelIdleTimer();
    _cancelAwayTimer();
  }

  Future<bool> _prompt(String reason) async {
    _prompts++;
    try {
      return await _device.authenticate(reason);
    } finally {
      _prompts--;
      if (_prompts == 0 && mounted) {
        // Catch up with where Pastee is now that the prompt has gone.
        if (_inFront) {
          _backInFront();
        } else {
          _leftFront();
        }
      }
    }
  }

  // ── passcode ───────────────────────────────────────────────────────────

  /// The result, and the hash the passcode matched.
  Future<(PasscodeResult, PasscodeHash?)> _check(String passcode) async {
    if (!mounted) return (PasscodeResult.wrong, null);
    final hash = _hash;
    if (hash == null) {
      // No passcode to check, unless the saved one couldn't be read.
      return (state.enabled ? PasscodeResult.wrong : PasscodeResult.ok, null);
    }
    _capLockout();
    if (lockoutRemaining != null) return (PasscodeResult.lockedOut, null);
    final right = await hash.verify(passcode);
    if (!mounted) return (PasscodeResult.wrong, null);
    if (right) {
      await _resetFailures();
      return (PasscodeResult.ok, hash);
    }
    await _recordFailure();
    return (
      lockoutRemaining != null
          ? PasscodeResult.lockedOut
          : PasscodeResult.wrong,
      null,
    );
  }

  /// Hashes made with fewer rounds (by an earlier Pastee) are made again once
  /// the passcode has been typed correctly.
  Future<void> _strengthen(PasscodeHash old, String passcode) {
    return _passcodeWrites.run(() async {
      if (!identical(_hash, old)) return; // changed or turned off meanwhile
      try {
        final stronger =
            await PasscodeHash.create(passcode, iterations: iterations);
        if (!mounted || !identical(_hash, old)) return;
        await _store.write(_kPasscode, stronger.toJson());
        _hash = stronger;
      } catch (_) {
        // Not saved. The old hash still works; this runs again next unlock.
      }
    });
  }

  /// A wait that ends more than 15 minutes from now was set while the clock
  /// was ahead (or the settings were edited): shorten it and save that.
  void _capLockout() {
    final until = state.lockedOutUntil;
    if (until == null) return;
    final latest = _clock().add(_maxLockout);
    if (!until.isAfter(latest)) return;
    state = state.copyWith(lockedOutUntil: () => latest);
    // If this fails, the wait is shortened again at the next launch.
    unawaited(Future.sync(
            () => _store.write(_kLockedOutUntil, latest.millisecondsSinceEpoch))
        .catchError((Object _) {}));
  }

  Future<void> _recordFailure() async {
    final failures = state.failures + 1;
    DateTime? until;
    if (failures >= freeAttempts) {
      final doublings = math.min(failures - freeAttempts, 5);
      final seconds = math.min(30 << doublings, _maxLockout.inSeconds);
      until = _clock().add(Duration(seconds: seconds));
    }
    state = state.copyWith(failures: failures, lockedOutUntil: () => until);
    await _store.write(_kFailures, failures);
    await _store.write(_kLockedOutUntil, until?.millisecondsSinceEpoch);
  }

  Future<void> _resetFailures() async {
    if (state.failures == 0 && state.lockedOutUntil == null) return;
    state = state.copyWith(failures: 0, lockedOutUntil: () => null);
    await _store.write(_kFailures, null);
    await _store.write(_kLockedOutUntil, null);
  }
}

/// Runs tasks one at a time, in the order they were added.
class _Serial {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
