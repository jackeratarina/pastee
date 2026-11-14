import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

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

  /// Slow enough to make guessing from a copied settings file expensive,
  /// fast enough to check in about half a second on a 2018 laptop.
  static const int defaultIterations = 310000;

  /// The shortest new passcode Pastee accepts. Only new passcodes are held to
  /// it; [verify] doesn't check it, so shorter passcodes set before keep
  /// working.
  static const int minLength = 6;

  /// Saved hashes outside these limits weren't made by Pastee. The settings
  /// file is damaged or was edited, and [fromJson] rejects them.
  static const int minIterations = 1000;
  static const int maxIterations = 10000000;
  static const int minSaltLength = 16;
  static const int hashLength = 32;

  /// Whether these are parameters Pastee makes. Others never verify: an empty
  /// hash would match any passcode, and a huge round count would hang.
  bool get isValid =>
      salt.length >= minSaltLength &&
      hash.length == hashLength &&
      iterations >= minIterations &&
      iterations <= maxIterations;

  static Future<PasscodeHash> create(String passcode,
      {int iterations = defaultIterations}) async {
    RangeError.checkValueInInterval(
        iterations, minIterations, maxIterations, 'iterations');
    final random = Random.secure();
    final salt = Uint8List.fromList(
        List.generate(minSaltLength, (_) => random.nextInt(256)));
    final hash = await _derive(passcode, salt, iterations, hashLength);
    return PasscodeHash(salt: salt, hash: hash, iterations: iterations);
  }

  Future<bool> verify(String passcode) async {
    if (!isValid) return false;
    final candidate = await _derive(passcode, salt, iterations, hash.length);
    return _constantTimeEquals(candidate, hash);
  }

  Map<String, Object> toJson() => {
        'salt': base64Encode(salt),
        'hash': base64Encode(hash),
        'iterations': iterations,
      };

  /// Null if [json] isn't a hash Pastee could have saved (see [isValid]).
  static PasscodeHash? fromJson(Object? json) {
    if (json is! Map) return null;
    final salt = json['salt'];
    final hash = json['hash'];
    final iterations = json['iterations'];
    if (salt is! String || hash is! String || iterations is! int) return null;
    try {
      final parsed = PasscodeHash(
        salt: base64Decode(salt),
        hash: base64Decode(hash),
        iterations: iterations,
      );
      return parsed.isValid ? parsed : null;
    } on FormatException {
      return null;
    }
  }

  /// Runs the key derivation off the UI thread when it's expensive.
  static Future<Uint8List> _derive(
      String passcode, Uint8List salt, int iterations, int length) {
    // The same passcode can arrive as different code points: "ậ" is one
    // character from most keyboards, but a + U+0323 + U+0302 from others
    // (Unikey's "Unicode tổ hợp", for one). Hash the composed form (NFC) so
    // they all match. Done here rather than in the isolate, which would have
    // to load the Unicode tables again every time.
    final password = utf8.encode(unorm.nfc(passcode));
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
///
/// HMAC's two padded key blocks are hashed once up front, so each iteration
/// costs two SHA-256 compressions instead of four, and allocates nothing.
Uint8List pbkdf2Sha256(
    List<int> password, List<int> salt, int iterations, int length) {
  if (iterations < 1) throw RangeError.range(iterations, 1, null, 'iterations');
  RangeError.checkNotNegative(length, 'length');
  final w = Uint32List(64);

  // HMAC key: hashed if longer than a block, then padded with zeros.
  final key = Uint8List(64);
  if (password.length > 64) {
    final digest = Uint32List(8);
    _hashTail(_iv, 0, password, w, digest);
    _putWords(key, 0, digest);
  } else {
    key.setAll(0, password);
  }
  final keyWords = ByteData.sublistView(key);
  final inner = Uint32List(8);
  final outer = Uint32List(8);
  for (var i = 0; i < 16; i++) {
    w[i] = keyWords.getUint32(4 * i) ^ 0x36363636;
  }
  _compress(_iv, w, inner);
  for (var i = 0; i < 16; i++) {
    w[i] = keyWords.getUint32(4 * i) ^ 0x5c5c5c5c;
  }
  _compress(_iv, w, outer);

  final blocks = (length + 31) ~/ 32;
  final result = Uint8List(blocks * 32);
  final message = Uint8List(salt.length + 4)..setAll(0, salt);
  final t = Uint32List(8);
  for (var block = 1; block <= blocks; block++) {
    // U1 = HMAC(password, salt || INT(block)).
    ByteData.sublistView(message).setUint32(salt.length, block);
    _hashTail(inner, 64, message, w, t);
    w.setAll(0, t);
    // From here on, w[0..7] holds the 32-byte message and w[8..15] its
    // padding (the key block came first, so 96 bytes in all). Each
    // compression below writes its result back into w[0..7].
    w[8] = 0x80000000;
    w.fillRange(9, 15, 0);
    w[15] = (64 + 32) * 8;
    _compress(outer, w, w);
    t.setRange(0, 8, w);
    for (var i = 1; i < iterations; i++) {
      // U(i) = HMAC(password, U(i - 1)).
      _compress(inner, w, w);
      _compress(outer, w, w);
      t[0] ^= w[0];
      t[1] ^= w[1];
      t[2] ^= w[2];
      t[3] ^= w[3];
      t[4] ^= w[4];
      t[5] ^= w[5];
      t[6] ^= w[6];
      t[7] ^= w[7];
    }
    _putWords(result, (block - 1) * 32, t);
  }
  return Uint8List.sublistView(result, 0, length);
}

// ── SHA-256 (FIPS 180-4) ──────────────────────────────────────────────────

final Uint32List _iv = Uint32List.fromList(const [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
]);

final Uint32List _k = Uint32List.fromList(const [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

/// The SHA-256 compression function: hashes the 64-byte block in `w[0..15]`
/// onto the chaining value [init] and writes the result to [out], which may
/// be [init] or `w` itself. [w] needs room for 64 words.
///
/// Values are kept in 64-bit ints: rotations leave junk above bit 31, which
/// is masked off where it matters (before `>>`) and dropped by the
/// [Uint32List] stores.
void _compress(Uint32List init, Uint32List w, Uint32List out) {
  final k = _k;
  for (var t = 16; t < 64; t++) {
    final x = w[t - 15];
    final y = w[t - 2];
    w[t] = (((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10)) +
        w[t - 7] +
        (((x >> 7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >> 3)) +
        w[t - 16];
  }
  var a = init[0], b = init[1], c = init[2], d = init[3];
  var e = init[4], f = init[5], g = init[6], h = init[7];
  for (var t = 0; t < 64; t++) {
    final t1 = h +
        (((e >> 6) | (e << 26)) ^
            ((e >> 11) | (e << 21)) ^
            ((e >> 25) | (e << 7))) +
        (g ^ (e & (f ^ g))) +
        k[t] +
        w[t];
    final t2 = (((a >> 2) | (a << 30)) ^
            ((a >> 13) | (a << 19)) ^
            ((a >> 22) | (a << 10))) +
        ((a & b) | (c & (a | b)));
    h = g;
    g = f;
    f = e;
    e = (d + t1) & 0xffffffff;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xffffffff;
  }
  out[0] = init[0] + a;
  out[1] = init[1] + b;
  out[2] = init[2] + c;
  out[3] = init[3] + d;
  out[4] = init[4] + e;
  out[5] = init[5] + f;
  out[6] = init[6] + g;
  out[7] = init[7] + h;
}

/// Finishes a SHA-256 hash: [message] and the final padding, hashed onto
/// [state], which already took in [prefixLength] bytes (whole blocks). The
/// digest goes to [out]; [state] is left alone.
void _hashTail(Uint32List state, int prefixLength, List<int> message,
    Uint32List w, Uint32List out) {
  final padded = Uint8List((message.length + 9 + 63) & ~63)
    ..setAll(0, message)
    ..[message.length] = 0x80;
  final bytes = ByteData.sublistView(padded);
  final bits = (prefixLength + message.length) * 8;
  bytes.setUint32(padded.length - 8, bits ~/ 0x100000000);
  bytes.setUint32(padded.length - 4, bits & 0xffffffff);
  final chain = Uint32List.fromList(state);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bytes.getUint32(offset + 4 * i);
    }
    _compress(chain, w, chain);
  }
  out.setAll(0, chain);
}

/// Writes the 8 words of [words] big-endian into [bytes] at [offset].
void _putWords(Uint8List bytes, int offset, Uint32List words) {
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < 8; i++) {
    view.setUint32(offset + 4 * i, words[i]);
  }
}
