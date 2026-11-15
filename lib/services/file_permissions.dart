import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Makes [path] private to your user account on Linux: mode 0700 for a
/// folder, 0600 for a file. dart:io can't change permissions, so this calls
/// chmod(2). Elsewhere it does nothing: on macOS the data lives in the private
/// ~/Library, and on Windows the key is protected with DPAPI.
///
/// Returns false if the mode couldn't be changed (a file system without
/// Unix permissions); Pastee still works, with the folder's existing mode.
bool restrictToOwner(String path, {required bool directory}) {
  if (!Platform.isLinux) return true;
  final ok = using((arena) =>
      _chmod(path.toNativeUtf8(allocator: arena),
          directory ? _ownerOnlyDirectory : _ownerOnlyFile) ==
      0);
  if (!ok) debugPrint('Pastee: could not make $path private (chmod failed)');
  return ok;
}

const _ownerOnlyDirectory = 0x1c0; // 0700
const _ownerOnlyFile = 0x180; // 0600

typedef _ChmodNative = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

final _chmod =
    DynamicLibrary.process().lookupFunction<_ChmodNative, _ChmodDart>('chmod');
