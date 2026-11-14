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
class AppLockNotifier extends StateNotifier<AppLockState> {
  AppLockNotifier(
    this._store,
    this._device, {
    this.iterations = PasscodeHash.defaultIterations,
    DateTime Function()? clock,
  })  : _clock = clock ?? (() => clock_package.clock.now()),
        super(const AppLockState()) {
    _hash = PasscodeHash.fromJson(_store.read(_kPasscode));
    final timeout = _store.read(_kTimeout);
    final lockout = _store.read(_kLockedOutUntil);
    state = AppLockState(
      enabled: _hash != null,
      // Always locked when Pastee starts.
      locked: _hash != null,
      deviceUnlock: _hash != null && _store.read(_kDeviceUnlock) == true,
      timeout: LockTimeout.values.firstWhere((t) => t.name == timeout,
          orElse: () => LockTimeout.fiveMinutes),
      failures: (_store.read(_kFailures) as int?) ?? 0,
      lockedOutUntil:
          lockout is int ? DateTime.fromMillisecondsSinceEpoch(lockout) : null,
    );
  }

  static const _kPasscode = 'lock.passcode';
  static const _kDeviceUnlock = 'lock.deviceUnlock';
  static const _kTimeout = 'lock.timeout';
  static const _kFailures = 'lock.failures';
  static const _kLockedOutUntil = 'lock.lockedOutUntil';

  /// Wrong passcodes allowed before a wait: 30 s, then doubling, up to 15 min.
  /// The count is saved, so restarting Pastee doesn't reset it.
  static const freeAttempts = 5;

  final SettingsStore _store;
  final DeviceAuthenticator _device;
  final int iterations;
  final DateTime Function() _clock;
  PasscodeHash? _hash;
  Timer? _awayTimer;

  /// Time left before passcode attempts are accepted again, or null.
  Duration? get lockoutRemaining {
    final until = state.lockedOutUntil;
    if (until == null) return null;
    final left = until.difference(_clock());
    return left > Duration.zero ? left : null;
  }

  /// Wrong passcodes left before a wait starts.
  int get attemptsLeft => math.max(0, freeAttempts - state.failures);

  /// Turns App Lock on (or changes the passcode). Pastee stays unlocked.
  Future<void> setPasscode(String passcode) async {
    final hash = await PasscodeHash.create(passcode, iterations: iterations);
    await _store.write(_kPasscode, hash.toJson());
    _hash = hash;
    await _resetFailures();
    state = state.copyWith(enabled: true, locked: false);
  }

  /// Turns App Lock off. Callers confirm the passcode first.
  Future<void> disable() async {
    _cancelAwayTimer();
    _hash = null;
    await _store.write(_kPasscode, null);
    await _store.write(_kDeviceUnlock, null);
    await _resetFailures();
    state = state.copyWith(enabled: false, locked: false, deviceUnlock: false);
  }

  /// Checks [passcode] without changing the lock, for confirming settings
  /// changes. Wrong attempts count toward the lockout.
  Future<PasscodeResult> checkPasscode(String passcode) async {
    final hash = _hash;
    if (hash == null) return PasscodeResult.ok;
    if (lockoutRemaining != null) return PasscodeResult.lockedOut;
    if (await hash.verify(passcode)) {
      await _resetFailures();
      return PasscodeResult.ok;
    }
    await _recordFailure();
    return lockoutRemaining != null
        ? PasscodeResult.lockedOut
        : PasscodeResult.wrong;
  }

  Future<PasscodeResult> unlockWithPasscode(String passcode) async {
    final result = await checkPasscode(passcode);
    if (result == PasscodeResult.ok) _unlock();
    return result;
  }

  /// Unlocks with Touch ID / Windows Hello, if that's turned on.
  Future<bool> unlockWithDevice() async {
    if (!state.enabled || !state.deviceUnlock) return false;
    final ok = await _device.authenticate('Unlock Pastee');
    if (ok) {
      await _resetFailures();
      _unlock();
    }
    return ok;
  }

  /// Asks the operating system to confirm it's you.
  Future<bool> confirmWithDevice(String reason) => _device.authenticate(reason);

  Future<void> setDeviceUnlock(bool on) async {
    if (!state.enabled) return;
    state = state.copyWith(deviceUnlock: on);
    await _store.write(_kDeviceUnlock, on);
  }

  Future<void> setTimeout(LockTimeout timeout) async {
    state = state.copyWith(timeout: timeout);
    await _store.write(_kTimeout, timeout.name);
  }

  void lock() {
    _cancelAwayTimer();
    if (state.enabled && !state.locked) state = state.copyWith(locked: true);
  }

  /// Pastee lost focus ([hidden] false) or was hidden or minimized. Starts the
  /// countdown, so Pastee is already locked when it next appears, and nothing
  /// it showed before flashes on screen.
  void wentAway({required bool hidden}) {
    if (!state.enabled || state.locked) return;
    final duration = state.timeout.duration;
    if (duration == null) return;
    if (duration == Duration.zero) {
      if (hidden) lock();
      return;
    }
    _awayTimer ??= Timer(duration, lock);
  }

  /// Pastee is in front again.
  void cameBack() => _cancelAwayTimer();

  void _unlock() {
    _cancelAwayTimer();
    state = state.copyWith(locked: false);
  }

  void _cancelAwayTimer() {
    _awayTimer?.cancel();
    _awayTimer = null;
  }

  Future<void> _recordFailure() async {
    final failures = state.failures + 1;
    DateTime? until;
    if (failures >= freeAttempts) {
      final doublings = math.min(failures - freeAttempts, 5);
      final seconds = math.min(30 << doublings, 15 * 60);
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

  @override
  void dispose() {
    _cancelAwayTimer();
    super.dispose();
  }
}
