import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// A salted PBKDF2-HMAC-SHA256 hash of the App Lock passcode. The passcode
/// itself is never stored.
@immutable
class PasscodeHash {
  const PasscodeHash({
    required this.salt,
    required this.hash,
    required this.iterations,
  });

  final Uint8List salt;
  final Uint8List hash;
  final int iterations;

  /// Slow enough to make guessing from a copied settings file expensive, fast
  /// enough to unlock in well under a second on a laptop.
  static const int defaultIterations = 120000;

  /// The shortest passcode Pastee accepts.
  static const int minLength = 4;

  static Future<PasscodeHash> create(String passcode,
      {int iterations = defaultIterations}) async {
    final random = Random.secure();
    final salt =
        Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
    final hash = await _derive(passcode, salt, iterations, 32);
    return PasscodeHash(salt: salt, hash: hash, iterations: iterations);
  }

  Future<bool> verify(String passcode) async {
    final candidate = await _derive(passcode, salt, iterations, hash.length);
    return _constantTimeEquals(candidate, hash);
  }

  Map<String, Object> toJson() => {
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iterations': iterations,
      };

  static PasscodeHash? fromJson(Object? json) {
    if (json is! Map) return null;
    final salt = json['salt'];
    final hash = json['hash'];
    final iterations = json['iterations'];
    if (salt is! String || hash is! String || iterations is! int) return null;
    try {
      return PasscodeHash(
        salt: base64Decode(salt),
        hash: base64Decode(hash),
        iterations: iterations,
      );
    } on FormatException {
      return null;
    }
  }

  /// Runs the key derivation off the UI thread when it's expensive.
  static Future<Uint8List> _derive(
      String passcode, Uint8List salt, int iterations, int length) {
    final password = utf8.encode(passcode);
    if (iterations < 20000) {
      return SynchronousFuture(
          pbkdf2Sha256(password, salt, iterations, length));
    }
    return Isolate.run(() => pbkdf2Sha256(password, salt, iterations, length));
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// PBKDF2 (RFC 8018) with HMAC-SHA256.
Uint8List pbkdf2Sha256(
    List<int> password, List<int> salt, int iterations, int length) {
  final hmac = Hmac(sha256, password);
  final result = BytesBuilder(copy: false);
  final blocks = (length + 31) ~/ 32;
  for (var block = 1; block <= blocks; block++) {
    final input = Uint8List(salt.length + 4)
      ..setAll(0, salt)
      ..[salt.length] = (block >> 24) & 0xff
      ..[salt.length + 1] = (block >> 16) & 0xff
      ..[salt.length + 2] = (block >> 8) & 0xff
      ..[salt.length + 3] = block & 0xff;
    var u = hmac.convert(input).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var k = 0; k < t.length; k++) {
        t[k] ^= u[k];
      }
    }
    result.add(t);
  }
  return Uint8List.sublistView(result.takeBytes(), 0, length);
}
