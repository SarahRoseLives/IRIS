import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

enum EncryptionStatus {
  none,
  pending,
  active,
  error,
}

class EncryptionSession {
  final SimpleKeyPair? myEphemeralKeyPair;
  SimplePublicKey? theirEphemeralPublicKey;
  EncryptionStatus status;
  SecretKey? sharedSecret;

  EncryptionSession({
    this.myEphemeralKeyPair,
    this.theirEphemeralPublicKey,
    this.status = EncryptionStatus.none,
    this.sharedSecret,
  });
}