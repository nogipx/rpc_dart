// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit findings (core audit, round 2) in the logger subsystem:
//
// 1. redaction.dart: redact/_redactDynamic recursed into nested Maps but NOT
//    Lists, so a sensitive field inside a list element (e.g. a list of objects)
//    passed through unredacted and leaked.
//
// 2. redaction.dart: the free-text pattern `(field[=:]\s?)...` had no word
//    boundary (so `mytoken=` was matched/corrupted as `token=`) and allowed
//    only one optional space (so `password = value` was not redacted).
//
// 3. log_controller.dart: the output dispatch loop had no try/catch and
//    iterated _outputs directly. A throwing synchronous output aborted delivery
//    to the remaining outputs AND propagated out of the logging call into the
//    caller's business code.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

class _CollectorOutput extends LogOutput {
  final List<LogRecord> records = [];
  @override
  void write(LogRecord record) => records.add(record);
}

class _ThrowingOutput extends LogOutput {
  @override
  void write(LogRecord record) => throw StateError('output boom');
}

void main() {
  group('LogRedactor recurses into lists', () {
    final redactor = LogRedactor(fields: ['password', 'token']);

    test('sensitive key inside a list element is redacted', () {
      final data = <String, Object>{
        'users': [
          {'name': 'alice', 'password': 'secret1'},
          {'name': 'bob', 'password': 'secret2'},
        ],
      };

      final result = redactor.redact(data);
      final users = (result['users'] as List).cast<Map<Object?, Object?>>();

      expect(users[0]['password'], '[REDACTED]');
      expect(users[1]['password'], '[REDACTED]');
      expect(users[0]['name'], 'alice');
    });

    test('nested list-of-list-of-map is redacted', () {
      final data = <String, Object>{
        'batches': [
          [
            {'token': 'leak'},
          ],
        ],
      };
      final result = redactor.redact(data);
      final inner = ((result['batches'] as List)[0] as List)[0] as Map;
      expect(inner['token'], '[REDACTED]');
    });
  });

  group('LogRedactor.redactString boundaries', () {
    final redactor = LogRedactor(fields: ['token', 'password']);

    test(
      'does not match a field name as a substring of a longer identifier',
      () {
        expect(
          redactor.redactString('mytoken=keepme'),
          'mytoken=keepme',
          reason: 'a field name inside an unrelated identifier must not match',
        );
      },
    );

    test('redacts a real field even with spaces around the separator', () {
      expect(
        redactor.redactString('password = spaced'),
        'password = [REDACTED]',
      );
    });

    test('redacts a normal token=value', () {
      expect(redactor.redactString('token=abc123'), 'token=[REDACTED]');
    });

    test('does not match a field name after a hyphen', () {
      expect(redactor.redactString('my-token=keepme'), 'my-token=keepme');
    });

    test(
      'redacts the credential of an authorization value, not the scheme',
      () {
        final auth = LogRedactor(fields: ['authorization']);
        expect(
          auth.redactString('authorization: Bearer eyJhbGciOi.secret next'),
          'authorization: [REDACTED] next',
        );
        expect(
          auth.redactString('Authorization=Basic dXNlcjpwYXNz'),
          'Authorization=[REDACTED]',
        );
      },
    );

    test('redacts a value inside JSON text', () {
      expect(
        redactor.redactString('{"password":"hunter 2","user":"bob"}'),
        '{"password":"[REDACTED]","user":"bob"}',
      );
      expect(
        redactor.redactString("{'token': 'abc'}"),
        "{'token': '[REDACTED]'}",
      );
    });

    test('redacts every parameter of a query string', () {
      expect(
        redactor.redactString('GET /login?token=abc123&x=1&password=hunter2'),
        'GET /login?token=[REDACTED]&x=1&password=[REDACTED]',
      );
    });
  });

  group('LogController isolates a throwing output', () {
    test(
      'a throwing output neither breaks the caller nor the other outputs',
      () {
        final good = _CollectorOutput();
        final controller = LogController(
          minLevel: RpcLogLevel.debug,
          // Throwing output first, so the good one is "after" it in the loop.
          outputs: [_ThrowingOutput(), good],
        );
        final log = controller.scope('test');

        // Must NOT throw into the caller.
        expect(() => log.info('hello'), returnsNormally);
        // The healthy output still received the record.
        expect(good.records, hasLength(1));

        controller.dispose();
      },
    );
  });
}
