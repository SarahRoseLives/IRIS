import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Generates a human-readable "Safety Number" for identity verification.
class SafetyNumberGenerator {
  // A pre-defined list of words for generating the safety number.
  // Using a smaller, more distinct list can improve usability.
  static const _wordList = [
    "apple", "bird", "blue", "cat", "dog", "fish",
    "green", "house", "ice", "juice", "key", "leaf",
    "moon", "nest", "orange", "pen", "queen", "red",
    "star", "tree", "umbrella", "violet", "water", "xenon",
    "yellow", "zebra", "zero", "one", "two", "three",
    "four", "five", "six", "seven", "eight", "nine"
  ];

  /// Generates a safety number from the two parties' public keys.
  /// The order of keys is normalized to ensure both users see the same number.
  static String generate({
    required Uint8List myPublicKey,
    required Uint8List theirPublicKey,
  }) {
    // 1. Normalize the order of keys by comparing them byte by byte.
    // This ensures both clients generate the same combined buffer.
    List<Uint8List> keys = [myPublicKey, theirPublicKey];
    keys.sort((a, b) {
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return a[i].compareTo(b[i]);
      }
      return 0;
    });

    // 2. Concatenate the sorted keys into a single buffer.
    final combinedKeys = Uint8List.fromList([...keys[0], ...keys[1]]);

    // 3. Hash the combined buffer to create a unique, fixed-size digest.
    final digest = sha256.convert(combinedKeys.toList());
    final hashBytes = Uint8List.fromList(digest.bytes);

    // 4. Convert the hash into a sequence of human-readable words.
    // We'll use the first 5 bytes to select 5 words from our list.
    final List<String> safetyWords = [];
    for (int i = 0; i < 5 && i < hashBytes.length; i++) {
      final index = hashBytes[i] % _wordList.length;
      safetyWords.add(_wordList[index]);
    }

    // 5. Take the next 2 bytes for two numbers between 0-99.
    final List<String> safetyNumbers = [];
    for (int i = 5; i < 7 && i < hashBytes.length; i++) {
      final number = hashBytes[i] % 100;
      safetyNumbers.add(number.toString().padLeft(2, '0'));
    }

    return '${safetyWords.join("-")} (${safetyNumbers.join("-")})';
  }
}