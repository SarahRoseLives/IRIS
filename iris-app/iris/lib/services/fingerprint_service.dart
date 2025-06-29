import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class FingerprintService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Only enable fingerprint on Android
  bool get isFingerprintSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> isFingerprintEnabled() async {
    if (!isFingerprintSupported) return false;
    return await _secureStorage.read(key: 'fingerprint_enabled') == 'true';
  }

  Future<void> setFingerprintEnabled(bool enabled) async {
    if (!isFingerprintSupported) return;
    await _secureStorage.write(
      key: 'fingerprint_enabled',
      value: enabled.toString(),
    );
  }

  Future<bool> canAuthenticate() async {
    if (!isFingerprintSupported) return false;
    try {
      return await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  Future<bool> authenticate() async {
    if (!isFingerprintSupported) return false;
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Authenticate to access IRIS',
        options: const AuthenticationOptions(
          biometricOnly: true,
          useErrorDialogs: true,
          stickyAuth: true,
        ),
      );
    } on PlatformException {
      return false;
    }
  }
}