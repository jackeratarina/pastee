import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// The operating system's own unlock: Touch ID (or the Mac login password)
/// on macOS, Windows Hello (fingerprint, face or PIN) on Windows. local_auth
/// has no Linux implementation, so on Linux App Lock is the passcode alone and
/// the option isn't offered.
abstract class DeviceAuthenticator {
  /// Whether this computer can do it at all.
  Future<bool> isAvailable();

  /// What to call it in the UI: "Touch ID", "Windows Hello"…
  Future<String> displayName();

  /// Shows the system prompt. True if the user passed it.
  Future<bool> authenticate(String reason);
}

class LocalAuthAuthenticator implements DeviceAuthenticator {
  LocalAuthAuthenticator();

  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.macOS &&
            defaultTargetPlatform != TargetPlatform.windows)) {
      return false;
    }
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> displayName() async {
    if (defaultTargetPlatform == TargetPlatform.windows) return 'Windows Hello';
    try {
      final biometrics = await _auth.getAvailableBiometrics();
      // Without Touch ID, macOS asks for the login password instead.
      return biometrics.isEmpty ? 'your Mac password' : 'Touch ID';
    } catch (_) {
      return 'Touch ID';
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // Allow the system password / PIN as a fallback to the fingerprint.
        biometricOnly: false,
        sensitiveTransaction: false,
      );
    } catch (_) {
      // LocalAuthException: not enrolled, locked out, cancelled by the system…
      return false;
    }
  }
}
