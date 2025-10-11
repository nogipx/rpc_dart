// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5, sha256;

import 'turn_password_algorithm.dart';

/// Credential store used by [TurnRelayServer] for TURN authentication.
abstract interface class TurnCredentialStore {
  /// TURN authentication realm advertised to clients.
  String get realm;

  /// Authentication nonce that clients must echo in requests.
  String get nonce;

  /// Validates that [nonce] is accepted for the current challenge.
  bool validateNonce(String nonce);

  /// Returns the credential registered for [username] if available.
  TurnCredential? lookup(String username);

  /// Password algorithms accepted by this store.
  List<TurnPasswordAlgorithm> get supportedAlgorithms;
}

/// Representation of credentials used during TURN authentication.
final class TurnCredential {
  TurnCredential({
    required this.username,
    required this.password,
    this.type = TurnCredentialType.longTerm,
    Iterable<TurnPasswordAlgorithm>? algorithms,
  }) : algorithms =
            List.unmodifiable(algorithms ?? TurnPasswordAlgorithm.values);

  /// Username advertised via the USERNAME attribute.
  final String username;

  /// Shared secret or password used to derive the message integrity key.
  final String password;

  /// TURN credential type used to derive the HMAC key.
  final TurnCredentialType type;

  /// Password algorithms supported by this credential.
  final List<TurnPasswordAlgorithm> algorithms;

  bool supportsAlgorithm(TurnPasswordAlgorithm algorithm) =>
      algorithms.contains(algorithm);

  /// Derives the HMAC key for [realm] according to RFC 5389 section 15.4.
  Uint8List deriveKey(String realm, TurnPasswordAlgorithm algorithm) {
    switch (type) {
      case TurnCredentialType.shortTerm:
        return Uint8List.fromList(utf8.encode(password));
      case TurnCredentialType.longTerm:
        final material = utf8.encode('$username:$realm:$password');
        return Uint8List.fromList(
          switch (algorithm) {
            TurnPasswordAlgorithm.hmacSha1Md5 => md5.convert(material).bytes,
            TurnPasswordAlgorithm.hmacSha256 =>
                sha256.convert(material).bytes,
          },
        );
    }
  }
}

/// Credential store backed by an in-memory map of usernames.
final class StaticTurnCredentialStore implements TurnCredentialStore {
  StaticTurnCredentialStore({
    required this.realm,
    required this.nonce,
    Map<String, TurnCredential>? credentials,
  })  : _credentials = Map.unmodifiable(credentials ?? const {}),
        _supportedAlgorithms = List.unmodifiable({
          for (final credential in (credentials ?? const {}).values)
            ...credential.algorithms,
        }.toList()
          ..sort((a, b) => a.wireValue.compareTo(b.wireValue)));

  final Map<String, TurnCredential> _credentials;
  final List<TurnPasswordAlgorithm> _supportedAlgorithms;

  @override
  final String realm;

  @override
  final String nonce;

  @override
  bool validateNonce(String nonce) => nonce == this.nonce;

  @override
  TurnCredential? lookup(String username) => _credentials[username];

  @override
  List<TurnPasswordAlgorithm> get supportedAlgorithms => _supportedAlgorithms;
}

/// Supported TURN authentication mechanisms.
enum TurnCredentialType {
  shortTerm,
  longTerm,
}
