import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/services/app_lock.dart';
import 'package:pastee/services/passcode.dart';
import 'package:pastee/services/storage_service.dart';

import 'support/fakes.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    // Reference values from Python's hashlib.pbkdf2_hmac.
    test('matches the reference implementation', () {
      List<int> b(String s) => utf8.encode(s);
      expect(hex(pbkdf2Sha256(b('password'), b('salt'), 1, 32)),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
      expect(hex(pbkdf2Sha256(b('password'), b('salt'), 2, 32)),
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
      expect(hex(pbkdf2Sha256(b('password'), b('salt'), 4096, 32)),
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
      expect(
          hex(pbkdf2Sha256(b('passwordPASSWORDpassword'),
              b('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 40)),
          '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9');
    });

    test('hashes are salted, verify, and survive JSON', () async {
      final a = await PasscodeHash.create('1234', iterations: testIterations);
      final b = await PasscodeHash.create('1234', iterations: testIterations);
      expect(a.hash, isNot(b.hash), reason: 'random salt');
      final restored =
          PasscodeHash.fromJson(jsonDecode(jsonEncode(a.toJson())))!;
      expect(await restored.verify('1234'), isTrue);
      expect(await restored.verify('12345'), isFalse);
      expect(PasscodeHash.fromJson({'salt': 1}), isNull);
    });

    test('the real iteration count runs off the UI thread in under 3 s',
        () async {
      final watch = Stopwatch()..start();
      final hash = await PasscodeHash.create('correct horse');
      expect(await hash.verify('correct horse'), isTrue);
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
    });
  });

  group('AppLockNotifier', () {
    late MemorySettingsStore store;
    late FakeAuthenticator device;
    late DateTime now;

    AppLockNotifier make() => AppLockNotifier(store, device,
        iterations: testIterations, clock: () => now);

    setUp(() {
      store = MemorySettingsStore();
      device = FakeAuthenticator();
      now = DateTime(2026, 11, 14, 12);
    });

    test('off by default; locked at every launch once a passcode is set',
        () async {
      final first = make();
      expect(first.state.enabled, isFalse);
      expect(first.state.locked, isFalse);

      await first.setPasscode('2580');
      expect(first.state.enabled, isTrue);
      expect(first.state.locked, isFalse,
          reason: 'setting it up does not lock you out');
      expect(store.values['lock.passcode'].toString(), isNot(contains('2580')));

      final relaunch = make();
      expect(relaunch.state.locked, isTrue);
      expect(await relaunch.unlockWithPasscode('0000'), PasscodeResult.wrong);
      expect(relaunch.state.locked, isTrue);
      expect(await relaunch.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(relaunch.state.locked, isFalse);
    });

    test(
        'five wrong passcodes start a wait that doubles and survives a restart',
        () async {
      await make().setPasscode('2580');
      var lock = make();
      for (var i = 0; i < 4; i++) {
        expect(await lock.unlockWithPasscode('nope'), PasscodeResult.wrong);
      }
      expect(lock.attemptsLeft, 1);
      expect(await lock.unlockWithPasscode('nope'), PasscodeResult.lockedOut);
      expect(lock.lockoutRemaining, const Duration(seconds: 30));

      // Even the right passcode is refused during the wait…
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.lockedOut);
      // …and restarting Pastee doesn't clear it.
      lock = make();
      expect(lock.lockoutRemaining, const Duration(seconds: 30));

      now = now.add(const Duration(seconds: 31));
      expect(await lock.unlockWithPasscode('nope'), PasscodeResult.lockedOut);
      expect(lock.lockoutRemaining, const Duration(seconds: 60),
          reason: 'doubles');

      now = now.add(const Duration(seconds: 61));
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(lock.state.failures, 0);
      expect(store.values['lock.failures'], isNull);
    });

    test('Touch ID / Windows Hello only unlocks when turned on', () async {
      await make().setPasscode('2580');
      final lock = make();
      expect(await lock.unlockWithDevice(), isFalse);
      expect(device.prompts, 0);

      await lock.setDeviceUnlock(true);
      device.succeeds = false;
      expect(await lock.unlockWithDevice(), isFalse);
      expect(lock.state.locked, isTrue);
      device.succeeds = true;
      expect(await lock.unlockWithDevice(), isTrue);
      expect(lock.state.locked, isFalse);
    });

    test('turning App Lock off removes the passcode and device unlock',
        () async {
      final lock = make();
      await lock.setPasscode('2580');
      await lock.setDeviceUnlock(true);
      await lock.disable();
      expect(lock.state.enabled, isFalse);
      expect(make().state.locked, isFalse);
      expect(store.values['lock.passcode'], isNull);
      expect(store.values['lock.deviceUnlock'], isNull);
    });

    testWidgets(
        'relocks after the chosen time away, or as soon as it is hidden',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      await lock.setTimeout(LockTimeout.oneMinute);

      lock.wentAway(hidden: false);
      await tester.pump(const Duration(seconds: 59));
      lock.cameBack();
      await tester.pump(const Duration(minutes: 5));
      expect(lock.state.locked, isFalse, reason: 'came back in time');

      lock.wentAway(hidden: false);
      lock.wentAway(hidden: true); // the timer keeps running, not restarted
      await tester.pump(const Duration(seconds: 61));
      expect(lock.state.locked, isTrue);

      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.immediately);
      lock.wentAway(hidden: false);
      expect(lock.state.locked, isFalse, reason: 'just losing focus');
      lock.wentAway(hidden: true);
      expect(lock.state.locked, isTrue);

      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.onlyAtLaunch);
      lock.wentAway(hidden: true);
      await tester.pump(const Duration(hours: 5));
      expect(lock.state.locked, isFalse);
      lock.dispose();
    });
  });
}
