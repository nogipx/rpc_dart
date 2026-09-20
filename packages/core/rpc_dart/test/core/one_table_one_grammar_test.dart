// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Two duplications where the copies had drifted into different behaviour.
//
// 1. HTTP status -> gRPC status was answered by two tables, six rows apart, and
//    ONE of the rows was retryability: `RpcRetryInterceptor` retries
//    `unavailable` and `resourceExhausted` and nothing else, so a gateway
//    timeout was retried over HTTP/2 and final over HTTP/1.1 -- same
//    deployment, same proxy, same application code.
//
// 2. `/Service/Method` was length-checked in three places with three numbers
//    (512 hardcoded, the policy's 1024, and 258 outbound) and three different
//    grammars -- so the layer an embedder could CONFIGURE was the loosest, and
//    raising the knob past 512 changed nothing because the responder refused
//    afterwards. A setting that silently ignored half its range.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('one HTTP-to-gRPC table', () {
    // The row that changed BEHAVIOUR rather than wording.
    test('504 is retryable, and it is the same answer on both transports', () {
      expect(grpcStatusFromHttpStatus(504), RpcStatus.unavailable);
    });

    test('the grpc-go rows are the grpc-go rows', () {
      expect(grpcStatusFromHttpStatus(400), RpcStatus.internal);
      expect(grpcStatusFromHttpStatus(401), RpcStatus.unauthenticated);
      expect(grpcStatusFromHttpStatus(403), RpcStatus.permissionDenied);
      expect(grpcStatusFromHttpStatus(404), RpcStatus.unimplemented);
      expect(grpcStatusFromHttpStatus(429), RpcStatus.unavailable);
      expect(grpcStatusFromHttpStatus(502), RpcStatus.unavailable);
      expect(grpcStatusFromHttpStatus(503), RpcStatus.unavailable);
    });

    // Kept beyond grpc-go's table because rpc_dart's own responders emit it.
    test('413 stays RESOURCE_EXHAUSTED: a size the caller can reduce', () {
      expect(grpcStatusFromHttpStatus(413), RpcStatus.resourceExhausted);
    });

    test('499 is CANCELLED, the inverse of the gateway mapping', () {
      expect(grpcStatusFromHttpStatus(499), RpcStatus.cancelled);
    });

    // The rule the HTTP/1.1 table's `>=400 -> invalidArgument` default broke.
    test('anything unmapped is UNKNOWN, not INTERNAL', () {
      for (final code in [402, 409, 410, 412, 415, 418, 500, 501, 505, 599]) {
        expect(
          grpcStatusFromHttpStatus(code),
          RpcStatus.unknown,
          reason: '$code: the peer said something gRPC has no meaning for',
        );
      }
    });
  });

  group('one method-path grammar', () {
    test('a valid path splits into service and method', () {
      expect(parseRpcMethodPath('/Svc/Method'), ('Svc', 'Method'));
    });

    test('a dotted service name survives', () {
      expect(parseRpcMethodPath('/myapp.v1.UserService/Get'), (
        'myapp.v1.UserService',
        'Get',
      ));
    });

    // The three layers disagreed on the grammar, not only the number: the
    // policy accepted anything non-empty with a leading slash.
    test('the grammar is the same one at every layer', () {
      const policy = RpcSecurityPolicy();
      for (final bad in [
        '',
        'Svc/Method', // no leading slash
        '/Svc', // two parts
        '/Svc/Method/Extra', // four parts
        '/Svc/', // empty method
        '//Method', // empty service
        '/Svc/Me thod', // space is not a token character
        '/Svc/Method\r\n', // header injection
      ]) {
        expect(parseRpcMethodPath(bad), isNull, reason: 'parse: "$bad"');
        expect(
          policy.isValidMethodPath(bad),
          isFalse,
          reason: 'policy: "$bad"',
        );
      }
    });

    // THE defect: the knob was monotone downward only.
    test('raising maxMethodPathLength past 512 now has an effect', () {
      final path = '/${'S' * 300}/${'M' * 300}'; // 602 characters
      expect(path.length, greaterThan(512));

      const raised = RpcSecurityPolicy(maxMethodPathLength: 1024);
      expect(
        raised.parseMethodPath(path),
        isNotNull,
        reason:
            'the responder pipeline held a fourth copy with 512 hardcoded and '
            'refused the path afterwards, so raising the knob did nothing',
      );
    });

    // GUARD: it must still bite DOWNWARD, or "the knob works" would be
    // satisfied by a knob that is ignored in both directions.
    test('GUARD: lowering it still refuses', () {
      const lowered = RpcSecurityPolicy(maxMethodPathLength: 8);
      expect(lowered.parseMethodPath('/Service/Method'), isNull);
      expect(lowered.parseMethodPath('/S/M'), isNotNull);
    });

    // The outbound constructor was the 258 answer, so a client could not send
    // a path the policy's own default describes.
    test('the outbound constructor accepts what the policy default does', () {
      final path = '/${'S' * 200}/${'M' * 200}'; // 402 characters, over 258
      expect(() => RpcMetadata.forClientRequestWithPath(path), returnsNormally);
    });
  });
}
