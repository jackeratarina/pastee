import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'file_permissions.dart';

/// Wraps the box encryption key before it is written to disk.
abstract class KeyProtector {
  /// Stored in the key file so a file written by one protector is never fed
  /// to another.
  int get id;
  Uint8List protect(Uint8List data);
  Uint8List unprotect(Uint8List data);
}

/// Stores the key as-is: in the user's private Library folder on macOS, and
/// on Linux in a data folder (mode 0700) and key file (0600) only your user
/// account can open. This keeps the data file unreadable if it is copied
/// somewhere on its own. (On macOS the login keychain would ask for your
/// password after every update of an unsigned build, and the App Sandbox would
/// ask for permission to open Pastee's own data, so neither is used. On Linux,
/// libsecret isn't used yet.)
class PlainKeyProtector implements KeyProtector {
  const PlainKeyProtector();

  @override
  int get id => 0;

  @override
  Uint8List protect(Uint8List data) => data;

  @override
  Uint8List unprotect(Uint8List data) => data;
}

/// Encrypts the key with Windows DPAPI, so it can only be unwrapped by the
/// same Windows user on the same machine. Copying the data folder, a backup or
/// a synced folder to another account is useless without that login.
class DpapiKeyProtector implements KeyProtector {
  DpapiKeyProtector() {
    if (!Platform.isWindows) throw UnsupportedError('DPAPI is Windows-only');
  }

  static const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN
  static final _entropy = utf8.encode('pastee-box-key-v1');

  late final _crypt32 = DynamicLibrary.open('crypt32.dll');
  late final _kernel32 = DynamicLibrary.open('kernel32.dll');
  late final _protect =
      _crypt32.lookupFunction<_CryptProtectNative, _CryptProtectDart>(
          'CryptProtectData');
  late final _unprotect =
      _crypt32.lookupFunction<_CryptUnprotectNative, _CryptUnprotectDart>(
          'CryptUnprotectData');
  late final _localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  @override
  int get id => 1;

  @override
  Uint8List protect(Uint8List data) => _run(data, encrypt: true);

  @override
  Uint8List unprotect(Uint8List data) => _run(data, encrypt: false);

  Uint8List _run(Uint8List data, {required bool encrypt}) {
    return using((arena) {
      final input = arena<_DataBlob>();
      final entropy = arena<_DataBlob>();
      final output = arena<_DataBlob>();

      final inputBytes = arena<Uint8>(max(data.length, 1));
      inputBytes.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = inputBytes;

      final entropyBytes = arena<Uint8>(_entropy.length);
      entropyBytes.asTypedList(_entropy.length).setAll(0, _entropy);
      entropy.ref
        ..cbData = _entropy.length
        ..pbData = entropyBytes;

      final ok = encrypt
          ? _protect(
              input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output)
          : _unprotect(
              input, nullptr, entropy, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) {
        throw StateError(
            encrypt ? 'CryptProtectData failed' : 'CryptUnprotectData failed');
      }
      try {
        return Uint8List.fromList(
            output.ref.pbData.asTypedList(output.ref.cbData));
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    });
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptProtectDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _CryptUnprotectNative = Int32 Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    Uint32,
    Pointer<_DataBlob>);
typedef _CryptUnprotectDart = int Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

/// Result of loading the box key.
class LoadedKey {
  const LoadedKey(this.bytes, {required this.created, this.unreadableBackup});

  final Uint8List bytes;

  /// A new key was generated (first launch, or the old one was unreadable).
  final bool created;

  /// Where an unreadable old key file was moved, if that happened.
  final String? unreadableBackup;
}

/// Keeps the 256-bit key that encrypts saved pastes in a small file:
/// 4 bytes "PSTK", a version byte, the protector id, then the wrapped key.
class FileKeyStore {
  FileKeyStore(this.file, {KeyProtector? protector})
      : protector = protector ?? const PlainKeyProtector();

  final File file;
  final KeyProtector protector;

  static const _magic = [0x50, 0x53, 0x54, 0x4B]; // PSTK
  static const _version = 1;

  Future<LoadedKey> loadOrCreate() async {
    String? backup;
    if (await file.exists()) {
      restrictToOwner(file.path, directory: false);
      final key = _tryRead(await file.readAsBytes());
      if (key != null) return LoadedKey(key, created: false);
      backup =
          '${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}';
      await file.rename(backup);
    }
    final random = Random.secure();
    final key =
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    final wrapped = protector.protect(key);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    // Private before the key goes in (Linux; see restrictToOwner).
    await tmp.create();
    restrictToOwner(tmp.path, directory: false);
    await tmp.writeAsBytes([..._magic, _version, protector.id, ...wrapped],
        flush: true);
    await tmp.rename(file.path);
    return LoadedKey(key, created: true, unreadableBackup: backup);
  }

  Uint8List? _tryRead(Uint8List bytes) {
    if (bytes.length < 6) return null;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return null;
    }
    if (bytes[4] != _version || bytes[5] != protector.id) return null;
    try {
      final key = protector.unprotect(Uint8List.sublistView(bytes, 6));
      return key.length == 32 ? key : null;
    } catch (_) {
      return null;
    }
  }
}
