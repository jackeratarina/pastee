// App Lock's logic, on its own: no UI, no test/support/fakes.dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pastee/services/app_lock.dart';
import 'package:pastee/services/device_auth.dart';
import 'package:pastee/services/passcode.dart';
import 'package:pastee/services/storage_service.dart';

/// Few PBKDF2 rounds keep the tests fast. 1,000 is also what the widget tests
/// save (test/support/fakes.dart), so it must stay a valid saved hash. Under
/// 20,000 the hashing runs synchronously, which testWidgets' fake async needs.
const testIterations = 1000;

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// "mật khẩu" ("password" in Vietnamese) three ways: precomposed (NFC), fully
/// decomposed (NFD, as some input methods type it), and with precomposed
/// vowels plus combining tone marks (the Windows Vietnamese keyboard).
const vietnameseNfc = 'm\u1EADt kh\u1EA9u';
const vietnameseNfd = 'ma\u0323\u0302t kha\u0302\u0309u';
const vietnameseMixed = 'm\u00E2\u0323t kh\u00E2\u0309u';

class FakeAuthenticator implements DeviceAuthenticator {
  bool succeeds = true;
  int prompts = 0;
  final reasons = <String>[];

  /// When set, the prompt stays up until the test completes this.
  Completer<bool>? reply;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String> displayName() async => 'Touch ID';

  @override
  Future<bool> authenticate(String reason) {
    prompts++;
    reasons.add(reason);
    return reply?.future ?? Future.value(succeeds);
  }
}

/// Settings that fail to save one key.
class FlakyStore extends MemorySettingsStore {
  String? failing;

  @override
  Future<void> write(String key, Object? value) async {
    if (key == failing) throw StateError('disk full');
    await super.write(key, value);
  }
}

void main() {
  group('PBKDF2-HMAC-SHA256', () {
    List<int> b(String s) => utf8.encode(s);

    // Reference values from Python's hashlib.pbkdf2_hmac.
    test('matches the reference implementation', () {
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

    test('…also for long keys, block-sized messages and longer output', () {
      // Also from hashlib: each one exercises a different path through
      // SHA-256's padding and HMAC's key handling.
      const salt = 'saltSALTsaltSALT';
      final cases = [
        // Keys over 64 bytes are hashed first.
        (
          b('k' * 100),
          b(salt),
          3,
          32,
          '648bf94a043084cd654ed58e26afd776593121908acf19c0ec5c826bbb737b84'
        ),
        (
          b('p' * 64),
          b(salt),
          3,
          32,
          'd20cd5a5bd801cd82540d2c603419048a81fc422c72046ba057c86f941ce8797'
        ),
        (
          b(''),
          b(''),
          2,
          32,
          '97398411d6aea43a77acef92226ab8278d4db0668bd1d7a76a725f7680ac45c5'
        ),
        // Salt + block number: 55 bytes still fit in one block with the
        // padding, 56 don't, 64 fill it, 124 take two.
        (
          b('password'),
          b('s' * 51),
          2,
          32,
          'c89fc63eaadc46a33ee5d193e494949c4cd1788be13c82c5f5a165d56cea4941'
        ),
        (
          b('password'),
          b('s' * 52),
          2,
          32,
          '4b96b36697e25a2eff1890de8eeb7155e7cc205374b48b8610bac6377068b77b'
        ),
        (
          b('password'),
          b('s' * 60),
          2,
          32,
          '44196bdb70213139d395e179a8fcdbec4d5cc309988d0edda2fb366c106ea9c1'
        ),
        (
          b('password'),
          b('s' * 120),
          2,
          32,
          '84c2bded6a6188b067a78256b8cec1cf78b6239352fbc53fcbb5132349a038ff'
        ),
        // Three output blocks, the last one cut short.
        (
          b('password'),
          b(salt),
          2,
          65,
          '2b77275cc3120b1513f6f3e03649fd493376526056cd04462aa6fef64a5d19f0'
              '32f7742b0848ef2997caffafdfa65c373955028f3606e3fe57d004a9731189aa3f'
        ),
      ];
      for (final (password, salt, iterations, length, expected) in cases) {
        expect(hex(pbkdf2Sha256(password, salt, iterations, length)), expected,
            reason: 'password ${password.length} bytes, '
                'salt ${salt.length} bytes, $length bytes out');
      }
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
      expect(PasscodeHash.defaultIterations, 310000);
      var ticks = 0;
      final ticker =
          Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
      addTearDown(ticker.cancel);
      final watch = Stopwatch()..start();
      final hash = await PasscodeHash.create('correct horse');
      expect(await hash.verify('correct horse'), isTrue);
      watch.stop();
      ticker.cancel();
      expect(hash.iterations, PasscodeHash.defaultIterations);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(ticks, greaterThan(10), reason: 'this isolate kept running');
    });

    test('new passcodes need 6 characters; shorter saved ones still verify',
        () async {
      expect(PasscodeHash.minLength, 6);
      // Hashes are made and checked whatever the length: the UI enforces it
      // for new passcodes only.
      final old = await PasscodeHash.create('2580', iterations: testIterations);
      expect(await old.verify('2580'), isTrue);
    });

    test('rejects hashes Pastee could not have saved', () async {
      Map<String, Object> saved(
              {int salt = 16, int hash = 32, int iterations = 310000}) =>
          {
            'salt': base64Encode(List.filled(salt, 1)),
            'hash': base64Encode(List.filled(hash, 2)),
            'iterations': iterations,
          };
      expect(PasscodeHash.fromJson(saved()), isNotNull);
      expect(PasscodeHash.fromJson(saved(salt: 32)), isNotNull);
      expect(PasscodeHash.fromJson(saved(iterations: 1000)), isNotNull);
      expect(PasscodeHash.fromJson(saved(iterations: 10000000)), isNotNull);

      expect(PasscodeHash.fromJson(saved(salt: 15)), isNull);
      expect(PasscodeHash.fromJson(saved(salt: 0)), isNull);
      expect(PasscodeHash.fromJson(saved(hash: 31)), isNull);
      expect(PasscodeHash.fromJson(saved(hash: 33)), isNull);
      expect(PasscodeHash.fromJson(saved(hash: 0)), isNull);
      expect(PasscodeHash.fromJson(saved(iterations: 999)), isNull);
      expect(PasscodeHash.fromJson(saved(iterations: 10000001)), isNull);
      expect(PasscodeHash.fromJson(saved(iterations: -1)), isNull);
      expect(
          PasscodeHash.fromJson(
              {...saved(), 'salt': 'not base64!'}), // FormatException
          isNull);
      expect(
          PasscodeHash.fromJson({...saved(), 'iterations': '310000'}), isNull);
      expect(PasscodeHash.fromJson('garbage'), isNull);
      expect(PasscodeHash.fromJson(null), isNull);

      // An empty hash used to match every passcode.
      final weak = PasscodeHash(
          salt: base64Decode(''), hash: base64Decode(''), iterations: 1);
      expect(weak.isValid, isFalse);
      expect(await weak.verify('anything'), isFalse);

      await expectLater(
          PasscodeHash.create('2580', iterations: 999), throwsRangeError);
      await expectLater(
          PasscodeHash.create('2580', iterations: 10000001), throwsRangeError);
    });

    test('a passcode matches however its accents were typed (NFC)', () async {
      expect(vietnameseNfd, isNot(vietnameseNfc));
      expect(utf8.encode(vietnameseNfd), isNot(utf8.encode(vietnameseNfc)));

      final composed =
          await PasscodeHash.create(vietnameseNfc, iterations: testIterations);
      expect(await composed.verify(vietnameseNfc), isTrue);
      expect(await composed.verify(vietnameseNfd), isTrue);
      expect(await composed.verify(vietnameseMixed), isTrue);
      expect(await composed.verify('mat khau'), isFalse);

      final decomposed =
          await PasscodeHash.create(vietnameseNfd, iterations: testIterations);
      expect(await decomposed.verify(vietnameseNfc), isTrue);
    });
  });

  group('AppLockNotifier', () {
    late MemorySettingsStore store;
    late FakeAuthenticator device;
    late DateTime now;

    /// For testWidgets: call dispose() at the end, before the test checks
    /// for pending timers.
    AppLockNotifier make({SettingsStore? settings, int? iterations}) =>
        AppLockNotifier(settings ?? store, device,
            iterations: iterations ?? testIterations, clock: () => now);

    /// For plain tests: disposed afterwards.
    AppLockNotifier open({SettingsStore? settings, int? iterations}) {
      final lock = make(settings: settings, iterations: iterations);
      addTearDown(lock.dispose);
      return lock;
    }

    /// Time passes: the clock moves on and timers fire.
    Future<void> wait(WidgetTester tester, Duration duration) async {
      now = now.add(duration);
      await tester.pump(duration);
    }

    /// The computer sleeps (or App Nap holds Pastee back): the clock moves on,
    /// but timers don't fire.
    void sleep(Duration duration) => now = now.add(duration);

    int? savedIterations() =>
        PasscodeHash.fromJson(store.values['lock.passcode'])?.iterations;

    setUp(() {
      store = MemorySettingsStore();
      device = FakeAuthenticator();
      now = DateTime(2026, 11, 14, 12);
    });

    test('off by default; locked at every launch once a passcode is set',
        () async {
      final first = open();
      expect(first.state.enabled, isFalse);
      expect(first.state.locked, isFalse);
      expect(await first.checkPasscode('anything'), PasscodeResult.ok,
          reason: 'no passcode to check');

      await first.setPasscode('2580');
      expect(first.state.enabled, isTrue);
      expect(first.state.locked, isFalse,
          reason: 'setting it up does not lock you out');
      expect(store.values['lock.passcode'].toString(), isNot(contains('2580')));

      final relaunch = open();
      expect(relaunch.state.locked, isTrue);
      expect(await relaunch.unlockWithPasscode('0000'), PasscodeResult.wrong);
      expect(relaunch.state.locked, isTrue);
      expect(await relaunch.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(relaunch.state.locked, isFalse);
    });

    test(
        'five wrong passcodes start a wait that doubles and survives a restart',
        () async {
      await open().setPasscode('2580');
      var lock = open();
      for (var i = 0; i < 4; i++) {
        expect(await lock.unlockWithPasscode('nope'), PasscodeResult.wrong);
      }
      expect(lock.attemptsLeft, 1);
      expect(await lock.unlockWithPasscode('nope'), PasscodeResult.lockedOut);
      expect(lock.lockoutRemaining, const Duration(seconds: 30));

      // Even the right passcode is refused during the wait…
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.lockedOut);
      // …and restarting Pastee doesn't clear it.
      lock = open();
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

    test('wrong passcodes sent all at once still stop after five', () async {
      await open().setPasscode('2580');
      final lock = open();
      final results = await Future.wait(
          [for (var i = 0; i < 12; i++) lock.unlockWithPasscode('nope')]);
      expect(results.where((r) => r == PasscodeResult.wrong), hasLength(4));
      expect(lock.state.failures, 5, reason: 'the rest waited their turn');
      expect(lock.lockoutRemaining, const Duration(seconds: 30));
    });

    test('Touch ID / Windows Hello only unlocks when turned on', () async {
      await open().setPasscode('2580');
      final lock = open();
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
      final lock = open();
      await lock.setPasscode('2580');
      await lock.setDeviceUnlock(true);
      await lock.disable();
      expect(lock.state.enabled, isFalse);
      expect(open().state.locked, isFalse);
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
      await tester.pump(const Duration(seconds: 50));
      expect(lock.state.locked, isFalse, reason: 'came back in time');

      lock.wentAway(hidden: false);
      lock.wentAway(hidden: true); // the timer keeps running, not restarted
      await tester.pump(const Duration(seconds: 61));
      expect(lock.state.locked, isTrue);

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.immediately);
      lock.wentAway(hidden: false);
      expect(lock.state.locked, isFalse, reason: 'just losing focus');
      lock.wentAway(hidden: true);
      expect(lock.state.locked, isTrue);

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.onlyAtLaunch);
      lock.wentAway(hidden: true);
      await tester.pump(const Duration(hours: 5));
      expect(lock.state.locked, isFalse);
      lock.dispose();
    });

    // 1 ───────────────────────────────────────────────────────────────────

    test('isLaunchLock: from launch until the first unlock', () async {
      final first = open();
      expect(first.isLaunchLock, isFalse, reason: 'App Lock is off');
      await first.setPasscode('2580');
      expect(first.isLaunchLock, isFalse, reason: 'turned on, not launched');
      first.lock();
      expect(first.isLaunchLock, isFalse);
      await first.setDeviceUnlock(true);

      final relaunch = open();
      expect(relaunch.isLaunchLock, isTrue);
      expect(await relaunch.unlockWithPasscode('0000'), PasscodeResult.wrong);
      expect(await relaunch.checkPasscode('2580'), PasscodeResult.ok);
      expect(relaunch.isLaunchLock, isTrue,
          reason: 'checking is not unlocking');
      expect(await relaunch.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(relaunch.isLaunchLock, isFalse);
      relaunch.lock();
      expect(relaunch.isLaunchLock, isFalse, reason: 'a later lock');

      final byDevice = open();
      expect(byDevice.isLaunchLock, isTrue);
      expect(await byDevice.unlockWithDevice(), isTrue);
      expect(byDevice.isLaunchLock, isFalse);

      final forgotten = open();
      expect(forgotten.isLaunchLock, isTrue);
      await forgotten.disable(); // "Forgot passcode?"
      expect(forgotten.isLaunchLock, isFalse);
    });

    // 2 ───────────────────────────────────────────────────────────────────

    testWidgets('locks after the timeout without input while in front',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580'); // five minutes
      await wait(tester, const Duration(minutes: 4));
      lock.userActive();
      await wait(tester, const Duration(minutes: 4));
      expect(lock.state.locked, isFalse, reason: 'input started it again');
      await wait(tester, const Duration(minutes: 1, seconds: 1));
      expect(lock.state.locked, isTrue);

      lock.userActive(); // locked: nothing to restart
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.immediately);
      await wait(tester, const Duration(seconds: 59));
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(seconds: 2));
      expect(lock.state.locked, isTrue,
          reason: '"as soon as hidden" allows a minute without input');

      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.onlyAtLaunch);
      lock.userActive();
      await wait(tester, const Duration(hours: 5));
      expect(lock.state.locked, isFalse);
      lock.dispose();
    });

    testWidgets('input after sleeping past the timeout locks', (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      sleep(const Duration(hours: 2)); // the timer never fired
      lock.userActive();
      expect(lock.state.locked, isTrue);
      lock.dispose();
    });

    testWidgets('input doesn\'t hold off the countdown while away',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      lock.wentAway(hidden: false);
      await wait(tester, const Duration(minutes: 4));
      lock.userActive(); // e.g. the pointer over the window behind
      await wait(tester, const Duration(minutes: 1, seconds: 1));
      expect(lock.state.locked, isTrue);
      lock.dispose();
    });

    // 3 ───────────────────────────────────────────────────────────────────

    test(
        'testDevice always asks; confirmWithDevice only if device unlock is on',
        () async {
      final lock = open();
      expect(await lock.testDevice('Use Touch ID to unlock Pastee'), isTrue,
          reason: 'even with App Lock off');
      await lock.setPasscode('2580');
      expect(await lock.confirmWithDevice('Turn off App Lock'), isFalse);
      expect(device.prompts, 1, reason: 'device unlock is off: no prompt');

      device.succeeds = false;
      expect(await lock.testDevice('Use Touch ID to unlock Pastee'), isFalse);
      device.succeeds = true;
      expect(await lock.testDevice('Use Touch ID to unlock Pastee'), isTrue);
      expect(device.prompts, 3);
      expect(lock.state.deviceUnlock, isFalse,
          reason: 'testing changes nothing');

      await lock.setDeviceUnlock(true);
      expect(await lock.confirmWithDevice('Turn off App Lock'), isTrue);
      expect(device.prompts, 4);
      expect(device.reasons.last, 'Turn off App Lock');

      await lock.disable();
      expect(await lock.confirmWithDevice('Turn off App Lock'), isFalse);
      expect(device.prompts, 4);
    });

    // 4 ───────────────────────────────────────────────────────────────────

    testWidgets(
        'coming back after the timeout locks, even if the timer is late',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580'); // five minutes
      lock.wentAway(hidden: true);
      sleep(const Duration(hours: 2));
      lock.cameBack();
      expect(lock.state.locked, isTrue, reason: 'checked on coming back');

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      lock.wentAway(hidden: false);
      sleep(const Duration(minutes: 10));
      lock.wentAway(hidden: true);
      expect(lock.state.locked, isTrue,
          reason: 'checked on going further away');

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      await lock.setTimeout(LockTimeout.immediately);
      lock.wentAway(hidden: false);
      sleep(const Duration(hours: 1));
      lock.cameBack();
      expect(lock.state.locked, isTrue,
          reason: 'more than 15 s behind other windows');
      lock.dispose();
    });

    testWidgets('time away starts afresh each time Pastee comes back',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      lock.wentAway(hidden: false);
      await wait(tester, const Duration(minutes: 4));
      lock.cameBack();
      expect(lock.state.locked, isFalse);
      lock.wentAway(hidden: false);
      await wait(tester, const Duration(minutes: 4));
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(minutes: 1, seconds: 1));
      expect(lock.state.locked, isTrue);
      lock.dispose();
    });

    testWidgets('"as soon as hidden" allows 15 s behind other windows',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      await lock.setTimeout(LockTimeout.immediately);
      lock.wentAway(hidden: false);
      await wait(tester, const Duration(seconds: 14));
      lock.wentAway(hidden: false); // doesn't restart it
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(seconds: 2));
      expect(lock.state.locked, isTrue);

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      lock.wentAway(hidden: false);
      await wait(tester, const Duration(seconds: 10));
      lock.cameBack();
      await wait(tester, const Duration(seconds: 10));
      expect(lock.state.locked, isFalse, reason: 'came back in time');
      lock.dispose();
    });

    testWidgets('an unlock that ends with Pastee away starts the countdown',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      lock.lock();
      // Switched to another app while the passcode was being checked: noted
      // even though Pastee was locked.
      final unlocking = lock.unlockWithPasscode('2580');
      lock.wentAway(hidden: false);
      expect(await unlocking, PasscodeResult.ok);
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(minutes: 4, seconds: 59));
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(seconds: 2));
      expect(lock.state.locked, isTrue, reason: 'five minutes away');

      await lock.setTimeout(LockTimeout.immediately);
      lock.wentAway(hidden: true);
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(lock.state.locked, isTrue, reason: 'unlocked while hidden');
      lock.dispose();
    });

    testWidgets(
        'focus going to another app after the system prompt starts the '
        'countdown', (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      await lock.setDeviceUnlock(true);
      lock.lock();
      device.reply = Completer<bool>();
      final unlocking = lock.unlockWithDevice();
      lock.wentAway(hidden: false); // the prompt takes the focus…
      device.reply!.complete(true); // …and it doesn't come back
      expect(await unlocking, isTrue);
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(minutes: 4, seconds: 59));
      expect(lock.state.locked, isFalse);
      await wait(tester, const Duration(seconds: 2));
      expect(lock.state.locked, isTrue);

      // Unlocked before the focus came back: the idle countdown takes over.
      device.reply = Completer<bool>();
      final again = lock.unlockWithDevice();
      device.reply!.complete(true);
      expect(await again, isTrue);
      lock.cameBack();
      await wait(tester, const Duration(minutes: 4));
      lock.userActive();
      await wait(tester, const Duration(minutes: 4));
      expect(lock.state.locked, isFalse);
      lock.dispose();
    });

    testWidgets('Pastee\'s own system prompt doesn\'t count as going away',
        (tester) async {
      final lock = make();
      await lock.setPasscode('2580');
      await lock.setTimeout(LockTimeout.immediately);
      device.reply = Completer<bool>();
      final testing = lock.testDevice('Use Touch ID to unlock Pastee');
      lock.wentAway(hidden: false); // the prompt takes the focus
      await wait(tester, const Duration(seconds: 20));
      expect(lock.state.locked, isFalse, reason: 'past 15 s, but no lock');
      lock.cameBack();
      device.reply!.complete(true);
      expect(await testing, isTrue);
      await wait(tester, const Duration(seconds: 59));
      expect(lock.state.locked, isFalse);

      await lock.setTimeout(LockTimeout.oneMinute);
      await lock.setDeviceUnlock(true);
      device.reply = Completer<bool>();
      final confirming = lock.confirmWithDevice('Turn off App Lock');
      lock.wentAway(hidden: false);
      sleep(const Duration(minutes: 10));
      lock.cameBack();
      device.reply!.complete(true);
      expect(await confirming, isTrue);
      expect(lock.state.locked, isFalse, reason: 'the prompt time is not away');
      lock.dispose();
    });

    // 5 ───────────────────────────────────────────────────────────────────

    test('a passcode change that finishes after a lock leaves Pastee locked',
        () async {
      // 20,000 rounds: hashing runs in an isolate, as in the app.
      final lock = open(iterations: 20000);
      await lock.setPasscode('2580');
      await lock.setTimeout(LockTimeout.immediately);

      final change = lock.setPasscode('1111'); // Settings → Change → Save
      lock.wentAway(hidden: true); // hidden while it hashes
      expect(lock.state.locked, isTrue);
      await change;
      expect(lock.state.locked, isTrue);
      expect(lock.state.enabled, isTrue);

      lock.cameBack();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.wrong);
      expect(await lock.unlockWithPasscode('1111'), PasscodeResult.ok);
      lock.lock();
      await lock.setPasscode('2222');
      expect(lock.state.locked, isTrue, reason: 'changed while locked');
    });

    // 6 ───────────────────────────────────────────────────────────────────

    test('a wait set while the clock was ahead is cut to 15 minutes', () async {
      now = DateTime(2027, 11, 14, 12); // a year ahead
      await open().setPasscode('2580');
      final lock = open();
      for (var i = 0; i < 5; i++) {
        await lock.unlockWithPasscode('0000');
      }
      expect(lock.lockoutRemaining, const Duration(seconds: 30));

      now = DateTime(2026, 11, 14, 12); // put right
      final relaunch = open();
      final latest = now.add(const Duration(minutes: 15));
      expect(relaunch.state.lockedOutUntil, latest);
      expect(relaunch.lockoutRemaining, const Duration(minutes: 15));
      expect(store.values['lock.lockedOutUntil'], latest.millisecondsSinceEpoch,
          reason: 'saved');
      expect(
          await relaunch.unlockWithPasscode('2580'), PasscodeResult.lockedOut);
      now = now.add(const Duration(minutes: 15, seconds: 1));
      expect(await relaunch.unlockWithPasscode('2580'), PasscodeResult.ok);
    });

    test('…also when the clock goes back while Pastee runs', () async {
      await open().setPasscode('2580');
      final lock = open();
      for (var i = 0; i < 5; i++) {
        await lock.unlockWithPasscode('0000');
      }

      now = now.subtract(const Duration(days: 1));
      expect(lock.lockoutRemaining, const Duration(minutes: 15),
          reason: 'capped straight away');
      await Future<void>.delayed(Duration.zero); // saved just after
      var latest = now.add(const Duration(minutes: 15));
      expect(lock.state.lockedOutUntil, latest);
      expect(
          store.values['lock.lockedOutUntil'], latest.millisecondsSinceEpoch);

      now = now.subtract(const Duration(days: 1));
      expect(await lock.checkPasscode('2580'), PasscodeResult.lockedOut);
      latest = now.add(const Duration(minutes: 15));
      expect(lock.state.lockedOutUntil, latest);
      expect(
          store.values['lock.lockedOutUntil'], latest.millisecondsSinceEpoch);
    });

    // 7 ───────────────────────────────────────────────────────────────────

    final unreadable = <String, Object>{
      'not a hash': 'garbage',
      'fields missing': {'salt': 1},
      'not base64': {'salt': '!!', 'hash': '!!', 'iterations': 310000},
      'empty hash, one round': {'salt': '', 'hash': '', 'iterations': 1},
      'salt too short': {
        'salt': base64Encode(List.filled(8, 1)),
        'hash': base64Encode(List.filled(32, 2)),
        'iterations': 310000,
      },
      'too many rounds': {
        'salt': base64Encode(List.filled(16, 1)),
        'hash': base64Encode(List.filled(32, 2)),
        'iterations': 10000001,
      },
    };
    unreadable.forEach((what, saved) {
      test(
          'an unreadable saved passcode ($what) stays locked until '
          '"Forgot passcode?"', () async {
        store.values['lock.passcode'] = saved;
        store.values['lock.deviceUnlock'] = true;
        final lock = open();
        expect(lock.state.enabled, isTrue);
        expect(lock.state.locked, isTrue);
        expect(lock.isLaunchLock, isTrue);
        expect(lock.state.deviceUnlock, isFalse);

        expect(await lock.checkPasscode(''), PasscodeResult.wrong);
        expect(await lock.checkPasscode('2580'), PasscodeResult.wrong);
        expect(await lock.unlockWithPasscode('2580'), PasscodeResult.wrong);
        expect(await lock.unlockWithDevice(), isFalse);
        await lock.setDeviceUnlock(true);
        expect(lock.state.deviceUnlock, isFalse, reason: 'can\'t be turned on');
        expect(await lock.unlockWithDevice(), isFalse);
        expect(await lock.confirmWithDevice('Turn off App Lock'), isFalse);
        expect(device.prompts, 0);
        expect(lock.state.locked, isTrue);

        await lock.disable(); // what "Forgot passcode?" does
        expect(lock.state.enabled, isFalse);
        expect(lock.state.locked, isFalse);
        expect(store.values['lock.passcode'], isNull);
        expect(open().state.locked, isFalse);
      });
    });

    testWidgets('if turning App Lock off fails, it stays on, passcode and all',
        (tester) async {
      final flaky = FlakyStore();
      final lock = make(settings: flaky);
      await lock.setPasscode('2580');

      flaky.failing = 'lock.passcode';
      await expectLater(lock.disable(), throwsStateError);
      expect(lock.state.enabled, isTrue);
      lock.lock();
      expect(await lock.unlockWithPasscode('not the passcode'),
          PasscodeResult.wrong);
      expect(lock.state.locked, isTrue);
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);

      // Saving fails part-way: the passcode is gone from disk, but this run
      // keeps it, and its countdowns.
      flaky.failing = 'lock.deviceUnlock';
      await expectLater(lock.disable(), throwsStateError);
      expect(lock.state.enabled, isTrue);
      await wait(tester, const Duration(minutes: 5, seconds: 1));
      expect(lock.state.locked, isTrue, reason: 'the idle countdown ran on');
      expect(await lock.unlockWithPasscode('nope'), PasscodeResult.wrong);
      expect(lock.state.locked, isTrue);
      lock.dispose();
    });

    // 8 ───────────────────────────────────────────────────────────────────

    test('a passcode with accents unlocks however they were typed', () async {
      final lock = open();
      await lock.setPasscode(vietnameseNfc);
      lock.lock();
      expect(await lock.unlockWithPasscode(vietnameseNfd), PasscodeResult.ok);

      await lock.setPasscode(vietnameseNfd);
      final relaunch = open();
      expect(await relaunch.unlockWithPasscode(vietnameseMixed),
          PasscodeResult.ok);
    });

    // 9 ───────────────────────────────────────────────────────────────────

    test('a hash with fewer rounds is made again after the next unlock',
        () async {
      await open().setPasscode('2580');
      expect(savedIterations(), testIterations);

      final lock = open(iterations: 2 * testIterations);
      expect(await lock.checkPasscode('2580'), PasscodeResult.ok);
      expect(savedIterations(), testIterations, reason: 'not an unlock');
      expect(await lock.unlockWithPasscode('0000'), PasscodeResult.wrong);
      expect(savedIterations(), testIterations);
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(savedIterations(), 2 * testIterations);
      lock.lock();
      expect(await lock.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(await lock.unlockWithPasscode('0000'), PasscodeResult.wrong);

      final relaunch = open(iterations: 2 * testIterations);
      expect(await relaunch.unlockWithPasscode('2580'), PasscodeResult.ok);

      // A hash with more rounds than asked for is left as it is.
      final fewer = open();
      expect(await fewer.unlockWithPasscode('2580'), PasscodeResult.ok);
      expect(savedIterations(), 2 * testIterations);
    });
  });
}
