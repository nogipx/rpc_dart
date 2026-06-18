// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: LogRedactor.redact only recursed into values whose static
// runtime type matched `Map<String, Object>`. JSON-decoded maps are typically
// `Map<String, dynamic>` (or untyped `Map`), so nested sensitive fields under
// such maps were NOT redacted and leaked into logs.
//
// redaction.dart (old):
//   } else if (entry.value is Map<String, Object>) {
//     result[entry.key] = redact(entry.value as Map<String, Object>);
//
// CONFIRMED if a sensitive key nested inside a Map<String, dynamic> survives
// redaction.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('LogRedactor recurses into maps of any generic type', () {
    final redactor = LogRedactor(fields: ['password', 'token']);

    test('nested Map<String, dynamic> sensitive key is redacted', () {
      // Typical JSON-decoded shape: Map<String, dynamic>.
      final Map<String, dynamic> nested = {
        'user': 'alice',
        'password': 'super-secret',
      };
      final data = <String, Object>{
        'event': 'login',
        'payload': nested,
      };

      final result = redactor.redact(data);
      final redactedPayload = result['payload'] as Map;

      expect(redactedPayload['password'], '[REDACTED]',
          reason: 'nested sensitive key must be redacted regardless of map '
              'generic type');
      expect(redactedPayload['user'], 'alice');
    });

    test('deeply nested untyped map sensitive key is redacted', () {
      final data = <String, Object>{
        'a': <String, dynamic>{
          'b': <dynamic, dynamic>{
            'TOKEN': 'leak-me', // case-insensitive match
          },
        },
      };

      final result = redactor.redact(data);
      final a = result['a'] as Map;
      final b = a['b'] as Map;

      expect(b['TOKEN'], '[REDACTED]',
          reason: 'case-insensitive match must apply to deeply nested maps');
    });

    test('null values inside nested maps do not crash redaction', () {
      final data = <String, Object>{
        'meta': <String, dynamic>{
          'password': 'x',
          'optional': null,
        },
      };

      final result = redactor.redact(data);
      final meta = result['meta'] as Map;

      expect(meta['password'], '[REDACTED]');
      expect(meta.containsKey('optional'), isFalse);
    });
  });
}
