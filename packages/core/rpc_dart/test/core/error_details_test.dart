// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('RpcErrorDetail encode/decode roundtrip', () {
    test('RpcBadRequest', () {
      final original = RpcBadRequest([
        RpcFieldViolation(field: 'email', description: 'invalid format'),
        RpcFieldViolation(field: 'age', description: 'must be >= 18'),
      ]);

      final any = original.encodeAsAny();
      final decoded = RpcErrorDetail.decodeAny(any);

      expect(decoded, isA<RpcBadRequest>());
      final br = decoded as RpcBadRequest;
      expect(br.violations.length, 2);
      expect(br.violations[0].field, 'email');
      expect(br.violations[0].description, 'invalid format');
      expect(br.violations[1].field, 'age');
      expect(br.violations[1].description, 'must be >= 18');
    });

    test('RpcRetryInfo', () {
      final original = RpcRetryInfo(Duration(seconds: 5, milliseconds: 500));

      final any = original.encodeAsAny();
      final decoded = RpcErrorDetail.decodeAny(any);

      expect(decoded, isA<RpcRetryInfo>());
      final ri = decoded as RpcRetryInfo;
      expect(ri.retryDelay.inMilliseconds, 5500);
    });

    test('RpcDebugInfo', () {
      final original = RpcDebugInfo(
        detail: 'NullPointerException',
        stackEntries: ['#0 Foo.bar (foo.dart:10)', '#1 main (main.dart:5)'],
      );

      final any = original.encodeAsAny();
      final decoded = RpcErrorDetail.decodeAny(any);

      expect(decoded, isA<RpcDebugInfo>());
      final di = decoded as RpcDebugInfo;
      expect(di.detail, 'NullPointerException');
      expect(di.stackEntries.length, 2);
      expect(di.stackEntries[0], '#0 Foo.bar (foo.dart:10)');
      expect(di.stackEntries[1], '#1 main (main.dart:5)');
    });

    test('RpcErrorInfo', () {
      final original = RpcErrorInfo(
        reason: 'QUOTA_EXCEEDED',
        domain: 'billing.v1',
        metadata: {'limit': '100', 'current': '105'},
      );

      final any = original.encodeAsAny();
      final decoded = RpcErrorDetail.decodeAny(any);

      expect(decoded, isA<RpcErrorInfo>());
      final ei = decoded as RpcErrorInfo;
      expect(ei.reason, 'QUOTA_EXCEEDED');
      expect(ei.domain, 'billing.v1');
      expect(ei.metadata, {'limit': '100', 'current': '105'});
    });

    test('unknown type preserved as RpcRawErrorDetail', () {
      final raw = RpcRawErrorDetail(
        typeUrl: 'type.googleapis.com/custom.MyError',
        value: Uint8List.fromList([1, 2, 3]),
      );

      final any = raw.encodeAsAny();
      final decoded = RpcErrorDetail.decodeAny(any);

      expect(decoded, isA<RpcRawErrorDetail>());
      final rd = decoded as RpcRawErrorDetail;
      expect(rd.typeUrl, 'type.googleapis.com/custom.MyError');
      expect(rd.value, [1, 2, 3]);
    });
  });

  group('encodeRpcStatus / decodeRpcStatus', () {
    test('roundtrip with multiple details', () {
      final details = [
        RpcBadRequest([
          RpcFieldViolation(field: 'name', description: 'required'),
        ]),
        RpcRetryInfo(Duration(seconds: 10)),
        RpcErrorInfo(reason: 'INVALID', domain: 'test'),
      ];

      final bytes = encodeRpcStatus(3, 'Validation failed', details);
      final result = decodeRpcStatus(bytes);

      expect(result.code, 3);
      expect(result.message, 'Validation failed');
      expect(result.details.length, 3);
      expect(result.details[0], isA<RpcBadRequest>());
      expect(result.details[1], isA<RpcRetryInfo>());
      expect(result.details[2], isA<RpcErrorInfo>());
    });

    test('empty details', () {
      final bytes = encodeRpcStatus(13, 'Internal error', []);
      final result = decodeRpcStatus(bytes);

      expect(result.code, 13);
      expect(result.message, 'Internal error');
      expect(result.details, isEmpty);
    });

    test('code zero omitted from wire', () {
      final bytes = encodeRpcStatus(0, '', []);
      // Empty status should produce empty bytes.
      expect(bytes.length, 0);
    });
  });

  group('RpcStatusException', () {
    test('statusDetailsBin encodes details', () {
      final ex = RpcStatusException(
        RpcStatus.invalidArgument,
        'bad input',
        details: [
          RpcBadRequest([
            RpcFieldViolation(field: 'x', description: 'too short'),
          ]),
        ],
      );

      final bin = ex.statusDetailsBin;
      expect(bin, isNotNull);

      final decoded = decodeRpcStatus(bin!);
      expect(decoded.code, RpcStatus.invalidArgument);
      expect(decoded.details.length, 1);
      expect(decoded.details[0], isA<RpcBadRequest>());
    });

    test('statusDetailsBin is null when no details', () {
      final ex = RpcStatusException(RpcStatus.notFound, 'not found');
      expect(ex.statusDetailsBin, isNull);
    });

    test('fromTrailer reconstructs details', () {
      final original = RpcStatusException(
        RpcStatus.resourceExhausted,
        'quota exceeded',
        details: [
          RpcRetryInfo(Duration(seconds: 30)),
          RpcErrorInfo(reason: 'LIMIT', domain: 'api'),
        ],
      );

      final reconstructed = RpcStatusException.fromTrailer(
        original.statusCode,
        original.message,
        detailsBin: original.statusDetailsBin,
      );

      expect(reconstructed.statusCode, RpcStatus.resourceExhausted);
      expect(reconstructed.message, 'quota exceeded');
      expect(reconstructed.details.length, 2);
      expect(reconstructed.details[0], isA<RpcRetryInfo>());
      expect(
        (reconstructed.details[0] as RpcRetryInfo).retryDelay.inSeconds,
        30,
      );
      expect(reconstructed.details[1], isA<RpcErrorInfo>());
      expect((reconstructed.details[1] as RpcErrorInfo).reason, 'LIMIT');
    });

    test('fromTrailer with null detailsBin returns no details', () {
      final ex = RpcStatusException.fromTrailer(5, 'not found');
      expect(ex.statusCode, 5);
      expect(ex.message, 'not found');
      expect(ex.details, isEmpty);
    });

    test('fromTrailer with corrupted detailsBin falls back gracefully', () {
      final ex = RpcStatusException.fromTrailer(
        13,
        'error',
        detailsBin: Uint8List.fromList([0xFF, 0xFF, 0xFF]),
      );
      expect(ex.statusCode, 13);
      expect(ex.message, 'error');
      expect(ex.details, isEmpty);
    });
  });

  group('RpcBadRequest edge cases', () {
    test('empty violations', () {
      final original = RpcBadRequest([]);
      final decoded = RpcErrorDetail.decodeAny(original.encodeAsAny());
      expect(decoded, isA<RpcBadRequest>());
      expect((decoded as RpcBadRequest).violations, isEmpty);
    });

    test('empty field and description', () {
      final original = RpcBadRequest([
        RpcFieldViolation(field: '', description: ''),
      ]);
      final decoded =
          RpcErrorDetail.decodeAny(original.encodeAsAny()) as RpcBadRequest;
      expect(decoded.violations.length, 1);
      expect(decoded.violations[0].field, '');
      expect(decoded.violations[0].description, '');
    });
  });

  group('RpcRetryInfo edge cases', () {
    test('zero duration', () {
      final original = RpcRetryInfo(Duration.zero);
      final decoded =
          RpcErrorDetail.decodeAny(original.encodeAsAny()) as RpcRetryInfo;
      expect(decoded.retryDelay, Duration.zero);
    });
  });

  group('RpcErrorInfo edge cases', () {
    test('empty metadata map', () {
      final original = RpcErrorInfo(reason: 'TEST', domain: 'x');
      final decoded =
          RpcErrorDetail.decodeAny(original.encodeAsAny()) as RpcErrorInfo;
      expect(decoded.reason, 'TEST');
      expect(decoded.domain, 'x');
      expect(decoded.metadata, isEmpty);
    });

    test('unicode in reason and metadata', () {
      final original = RpcErrorInfo(
        reason: 'ОШИБКА',
        domain: 'тест.v1',
        metadata: {'ключ': 'значение'},
      );
      final decoded =
          RpcErrorDetail.decodeAny(original.encodeAsAny()) as RpcErrorInfo;
      expect(decoded.reason, 'ОШИБКА');
      expect(decoded.domain, 'тест.v1');
      expect(decoded.metadata['ключ'], 'значение');
    });
  });
}
