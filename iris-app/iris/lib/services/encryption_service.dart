import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';

import '../models/encryption_session.dart';
import '../utils/safety_number_generator.dart';

class EncryptionService {
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const _identityKeyStorageKey = 'iris_identity_key';

  SimpleKeyPair? _identityKeyPair;
  final Map<String, EncryptionSession> _sessions = {};
  final x25519 = X25519();

  Future<void> initialize() async {
    await _loadOrCreateIdentityKey();
  }

  Future<void> _loadOrCreateIdentityKey() async {
    try {
      final keyHex = await _secureStorage.read(key: _identityKeyStorageKey);
      if (keyHex != null) {
        final keyBytes = Uint8List.fromList(hex.decode(keyHex));
        _identityKeyPair = await x25519.newKeyPairFromSeed(keyBytes);
      } else {
        _identityKeyPair = await x25519.newKeyPair();
        final private = await _identityKeyPair!.extractPrivateKeyBytes();
        await _secureStorage.write(
          key: _identityKeyStorageKey,
          value: hex.encode(private),
        );
      }
    } catch (e) {
      print('[EncryptionService] Identity key error: $e');
    }
  }

  /// Clears all active encryption sessions from memory.
  void reset() {
    _sessions.clear();
    print('[EncryptionService] All encryption sessions cleared.');
  }

  EncryptionStatus getSessionStatus(String target) =>
      _sessions[target.toLowerCase()]?.status ?? EncryptionStatus.none;

  Future<String?> initiateEncryption(String target) async {
    if (_identityKeyPair == null) return null;

    final eph = await x25519.newKeyPair();
    final ephPublic = await eph.extractPublicKey();
    _sessions[target.toLowerCase()] = EncryptionSession(
      myEphemeralKeyPair: eph,
      status: EncryptionStatus.pending,
    );
    return '[ENCRYPTION-REQUEST] ${base64Url.encode(ephPublic.bytes)}';
  }

  Future<String?> handleEncryptionRequest(String from, String requestPayload) async {
    if (_identityKeyPair == null) return null;
    final theirPubBytes = base64Url.decode(requestPayload);
    final theirPub = SimplePublicKey(theirPubBytes, type: KeyPairType.x25519);
    final myEph = await x25519.newKeyPair();

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: myEph,
      remotePublicKey: theirPub,
    );

    _sessions[from.toLowerCase()] = EncryptionSession(
      myEphemeralKeyPair: myEph,
      theirEphemeralPublicKey: theirPub,
      status: EncryptionStatus.active,
      sharedSecret: sharedSecret,
    );
    final myEphPub = await myEph.extractPublicKey();
    return '[ENCRYPTION-ACCEPT] ${base64Url.encode(myEphPub.bytes)}';
  }

  Future<void> handleEncryptionAcceptance(String from, String payload) async {
    final sess = _sessions[from.toLowerCase()];
    if (sess == null || sess.status != EncryptionStatus.pending) return;

    final theirPubBytes = base64Url.decode(payload);
    final theirPub = SimplePublicKey(theirPubBytes, type: KeyPairType.x25519);
    sess.theirEphemeralPublicKey = theirPub;

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: sess.myEphemeralKeyPair!,
      remotePublicKey: theirPub,
    );

    sess
      ..sharedSecret = sharedSecret
      ..status = EncryptionStatus.active;
  }

  Future<String?> encryptMessage(String target, String plaintext) async {
    final sess = _sessions[target.toLowerCase()];
    if (sess?.status != EncryptionStatus.active || sess?.sharedSecret == null) return null;

    final aes = AesGcm.with256bits();
    final secretKey = sess!.sharedSecret!;
    final nonce = aes.newNonce();
    final secretBox = await aes.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonce,
    );
    // Encode: nonce + ciphertext + mac
    final payload = <int>[
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ];
    return '[ENC]${base64Url.encode(payload)}';
  }

  Future<String?> decryptMessage(String from, String encryptedPayload) async {
    final sess = _sessions[from.toLowerCase()];
    if (sess?.status != EncryptionStatus.active || sess?.sharedSecret == null) return null;

    final data = base64Url.decode(encryptedPayload);
    final aes = AesGcm.with256bits();
    final nonce = data.sublist(0, 12); // AES-GCM standard nonce length
    final cipherText = data.sublist(12, data.length - 16);
    final mac = Mac(data.sublist(data.length - 16));
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);

    final plain = await aes.decrypt(
      secretBox,
      secretKey: sess!.sharedSecret!,
    );
    return utf8.decode(plain);
  }

  String endEncryption(String target) {
    _sessions.remove(target.toLowerCase());
    return '[ENCRYPTION-END]';
  }

  Future<String?> getSafetyNumber(String target) async {
    final sess = _sessions[target.toLowerCase()];
    if (sess?.status != EncryptionStatus.active ||
        sess?.theirEphemeralPublicKey == null ||
        sess?.myEphemeralKeyPair == null) return null;

    final myPub = await sess!.myEphemeralKeyPair!.extractPublicKey();
    return SafetyNumberGenerator.generate(
      myPublicKey: Uint8List.fromList(myPub.bytes),
      theirPublicKey: Uint8List.fromList(sess.theirEphemeralPublicKey!.bytes),
    );
  }
}