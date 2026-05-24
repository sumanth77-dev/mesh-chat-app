// ============================================================
// FILE: lib/services/encryption_service.dart
// PURPOSE: AES-128 encryption for message content.
//
// HOW IT WORKS:
//   - We use AES in CBC mode with PKCS7 padding.
//   - A shared secret key is derived from a fixed passphrase
//     using MD5 (simple, good enough for offline mesh demo).
//   - Intermediate relay nodes only see encrypted bytes —
//     they forward without decrypting.
//
// IMPORTANT: In production, use proper key exchange (e.g. ECDH).
// For this demo, all devices share the same passphrase.
// ============================================================

import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart';      // for MD5 key derivation
import 'package:encrypt/encrypt.dart' as enc; // AES encrypt/decrypt

class EncryptionService {
  // -----------------------------------------------------------
  // SHARED SECRET
  // In a real app this would be exchanged securely per-pair.
  // For the mesh demo all devices share this passphrase.
  // -----------------------------------------------------------
  static const String _passphrase = 'RelayX_MeshKey_2025';

  late final enc.Key _key;
  late final enc.Encrypter _encrypter;

  EncryptionService() {
    // Derive a 16-byte (128-bit) AES key from the passphrase via MD5
    final passphraseBytes = utf8.encode(_passphrase);
    final keyBytes = md5.convert(passphraseBytes).bytes;
    _key = enc.Key(Uint8List.fromList(keyBytes));
    _encrypter = enc.Encrypter(enc.AES(_key, mode: enc.AESMode.cbc));
  }

  // -----------------------------------------------------------
  // encryptMessage()
  // Takes plain text → returns "IV:CipherText" (both Base64)
  // The IV (Initialization Vector) is random each call for security.
  // -----------------------------------------------------------
  String encryptMessage(String plainText) {
    try {
      // Generate a random 16-byte IV for this encryption
      final random = Random.secure();
      final ivBytes = Uint8List.fromList(
        List<int>.generate(16, (_) => random.nextInt(256)),
      );
      final iv = enc.IV(ivBytes);

      final encrypted = _encrypter.encrypt(plainText, iv: iv);

      // Encode IV and cipher text as Base64, join with ':'
      final ivBase64 = base64.encode(ivBytes);
      final cipherBase64 = encrypted.base64;

      return '$ivBase64:$cipherBase64';
    } catch (e) {
      // If encryption fails (shouldn't happen), return plain text
      // so the app doesn't crash. Log the error for debugging.
      print('⚠️ Encryption error: $e — sending as plain text');
      return plainText;
    }
  }

  // -----------------------------------------------------------
  // decryptMessage()
  // Takes "IV:CipherText" → returns the original plain text.
  // -----------------------------------------------------------
  String decryptMessage(String encryptedText) {
    try {
      // Split the IV and cipher text
      final parts = encryptedText.split(':');
      if (parts.length < 2) {
        // Not in our format — return as-is (plain text fallback)
        return encryptedText;
      }

      final ivBytes = base64.decode(parts[0]);
      // The cipher may contain ':' characters if the base64 has them,
      // so rejoin everything after the first ':'
      final cipherBase64 = parts.sublist(1).join(':');

      final iv = enc.IV(Uint8List.fromList(ivBytes));
      final encrypted = enc.Encrypted.fromBase64(cipherBase64);

      return _encrypter.decrypt(encrypted, iv: iv);
    } catch (e) {
      print('⚠️ Decryption error: $e — returning raw text');
      // Return the raw text so the app doesn't crash
      return encryptedText;
    }
  }

  // -----------------------------------------------------------
  // Convenience: check if a string looks like our encrypted format
  // -----------------------------------------------------------
  bool isEncryptedFormat(String text) {
    // Our format is always two Base64 strings separated by ':'
    // A rough check: contains ':' and the first part is 24 chars (16 bytes base64)
    final parts = text.split(':');
    return parts.length >= 2 && parts[0].length == 24;
  }
}
