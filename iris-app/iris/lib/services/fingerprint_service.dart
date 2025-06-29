import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class FingerprintService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  // Key for the master setting
  static const _fingerprintEnabledKey = 'fingerprint_enabled';
  // Keys for the stored credentials
  static const _usernameKey = 'fingerprint_username';
  static const _passwordKey = 'fingerprint_password';

  /// Only enable fingerprint on Android
  bool get isFingerprintSupported => defaultTargetPlatform == TargetPlatform.android;

  /// Checks if the user has previously enabled fingerprint login.
  Future<bool> isFingerprintEnabled() async {
    if (!isFingerprintSupported) return false;
    return await _secureStorage.read(key: _fingerprintEnabledKey) == 'true';
  }

  /// Enables or disables the fingerprint login feature.
  /// When disabling, it also clears the stored credentials.
  Future<void> setFingerprintEnabled(bool enabled) async {
    if (!isFingerprintSupported) return;
    await _secureStorage.write(
      key: _fingerprintEnabledKey,
      value: enabled.toString(),
    );
    // If disabling, ensure credentials are cleared.
    if (!enabled) {
      await _secureStorage.delete(key: _usernameKey);
      await _secureStorage.delete(key: _passwordKey);
    }
  }

  /// Saves credentials to secure storage. This should be called
  /// only when the feature is being enabled.
  Future<void> saveCredentials(String username, String password) async {
    if (!isFingerprintSupported) return;
    await _secureStorage.write(key: _usernameKey, value: username);
    await _secureStorage.write(key: _passwordKey, value: password);
  }

  /// Retrieves the stored username and password.
  Future<Map<String, String>?> getCredentials() async {
    if (!isFingerprintSupported) return null;
    final username = await _secureStorage.read(key: _usernameKey);
    final password = await _secureStorage.read(key: _passwordKey);
    if (username != null && password != null) {
      return {'username': username, 'password': password};
    }
    return null;
  }

  /// Checks if the device has biometric capabilities.
  Future<bool> canAuthenticate() async {
    if (!isFingerprintSupported) return false;
    try {
      return await _localAuth.canCheckBiometrics ||
          await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// Prompts the user for biometric authentication.
  Future<bool> authenticate(
      {String localizedReason = 'Authenticate to access IRIS'}) async {
    if (!isFingerprintSupported) return false;
    try {
      return await _localAuth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: true, // Only allow biometrics (fingerprint, face)
          useErrorDialogs: true,
          stickyAuth: true,
      ),
      );
    } on PlatformException {
      return false;
    }
  }
}