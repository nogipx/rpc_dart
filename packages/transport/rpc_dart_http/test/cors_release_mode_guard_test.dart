// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcHttpCorsPolicy guarded `allowCredentials` + a '*' origin with an `assert`.
// Dart strips asserts in release builds -- and measured, the guard was weaker
// still: `dart run` does not enable asserts either, so it only ever fired under
// `dart test`. Everywhere real code runs, the invalid pair was accepted:
//
//   dart run --no-enable-asserts:
//     construction: ACCEPTED
//     access-control-allow-origin      = *
//     access-control-allow-credentials = true
//
//   after:
//     construction: rejected -> ArgumentError
//
// Not a breach: browsers reject Access-Control-Allow-Origin: * together with
// Access-Control-Allow-Credentials: true, so the result was a server whose
// every cross-origin call failed with nothing pointing at the cause.
//
// Core swept this class already -- see
// rpc_dart/test/audit/release_mode_config_guards_test.dart, "Every remaining
// assert in lib/ guarded a user-supplied configuration value ... They are now
// ArgumentError throws, which hold in every build mode." That sweep did not
// reach the transport packages.
//
// NOTE: like the core file, this runs with asserts ENABLED, as `dart test`
// always does, so it cannot observe release behaviour directly. What it pins is
// that the guard is no longer assert-shaped: an ArgumentError from a normal
// code path exists in both modes, an AssertionError does not.

import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

/// Fails if [body] throws an [AssertionError] -- the shape that vanishes in
/// release -- and returns whatever else it throws.
Object? _throwsNonAssertion(void Function() body) {
  try {
    body();
    return null;
  } on AssertionError catch (e) {
    fail('guarded with an assert, which is stripped outside `dart test`: $e');
  } catch (e) {
    return e;
  }
}

void main() {
  group('credentials + wildcard origin', () {
    // WITNESS: an AssertionError here (or nothing at all) is the defect.
    test('is rejected with a real throw, not an assert', () {
      final error = _throwsNonAssertion(
        () => RpcHttpCorsPolicy(allowedOrigins: ['*'], allowCredentials: true),
      );

      expect(
        error,
        isA<ArgumentError>(),
        reason:
            'the invalid pair was accepted (got $error); browsers reject '
            'Allow-Origin: * with Allow-Credentials: true, so every '
            'cross-origin call would fail',
      );
    });

    test('the message names both the cause and the fix', () {
      final error = _throwsNonAssertion(
        () => RpcHttpCorsPolicy(
          allowedOrigins: ['https://a.example', '*'],
          allowCredentials: true,
        ),
      );

      expect('$error', contains('allowCredentials'));
      expect('$error', contains('explicit origins'));
    });
  });

  group('valid configurations still construct', () {
    // GUARDS: pass on both sides. The throw must not catch anything legal.
    test('wildcard without credentials is allowed', () {
      final policy = RpcHttpCorsPolicy(allowedOrigins: ['*']);
      final headers = <String, String>{};
      policy.applyTo(headers, 'https://anywhere.example');

      expect(headers['access-control-allow-origin'], '*');
      expect(headers.containsKey('access-control-allow-credentials'), isFalse);
    });

    test('credentials with explicit origins are allowed', () {
      final policy = RpcHttpCorsPolicy(
        allowedOrigins: ['https://app.example'],
        allowCredentials: true,
      );
      final headers = <String, String>{};
      policy.applyTo(headers, 'https://app.example');

      expect(headers['access-control-allow-origin'], 'https://app.example');
      expect(headers['access-control-allow-credentials'], 'true');
    });

    test('the secure default stays closed', () {
      final policy = RpcHttpCorsPolicy();
      final headers = <String, String>{};
      policy.applyTo(headers, 'https://evil.example');

      expect(
        headers,
        isEmpty,
        reason: 'no allowed origins means no cross-origin access',
      );
    });

    test('an unlisted origin gets nothing', () {
      final policy = RpcHttpCorsPolicy(
        allowedOrigins: ['https://app.example'],
        allowCredentials: true,
      );
      final headers = <String, String>{};
      policy.applyTo(headers, 'https://evil.example');

      expect(headers, isEmpty);
    });
  });
}
