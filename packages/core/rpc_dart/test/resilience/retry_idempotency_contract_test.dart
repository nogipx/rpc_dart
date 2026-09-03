// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcRetryInterceptor's default predicate was documented as avoiding
// "re-issuing non-idempotent calls (e.g. a write that committed server-side but
// lost its response)". The example was backwards: a lost response IS
// UNAVAILABLE, which the default retries.
//
// Measured with a handler that commits and THEN loses its response, for one
// logical call at maxAttempts: 3:
//
//   response lost once  -> 2 server-side commits, caller saw SUCCESS
//   response lost twice -> 3 server-side commits, caller saw SUCCESS
//   no loss (control)   -> 1 commit
//
// Retrying UNAVAILABLE is the standard gRPC trade-off and the default is left
// alone. These tests pin what is actually guaranteed, so a future change to the
// predicate has to confront it:
//
//   - an arbitrary application error is never retried  (the real guarantee)
//   - UNAVAILABLE after a commit duplicates it         (the trade-off)
//   - a custom retryOn can exclude it                  (the escape hatch)

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Stands in for a side effect that cannot be undone.
int _commits = 0;

/// How many times the response is lost AFTER the commit.
int _loseAfterCommit = 0;

/// How many times the handler fails BEFORE committing, as an application error.
int _appErrorsBeforeCommit = 0;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'charge',
      handler: (request, {RpcContext? context}) async {
        if (_appErrorsBeforeCommit > 0) {
          _appErrorsBeforeCommit--;
          // Nothing committed: an ordinary application failure.
          throw RpcStatusException(RpcStatus.internal, 'business rule');
        }
        // The commit happens first -- money moves, row inserted.
        _commits++;
        if (_commits <= _loseAfterCommit) {
          // ...and the response never makes it back. On a real network this is
          // a dropped connection, which the framework surfaces as UNAVAILABLE.
          throw RpcStatusException(
            RpcStatus.unavailable,
            'No response received',
          );
        }
        return 'charged'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Makes one logical call through a retrying caller. Returns the result the
/// caller saw and how many times the server committed.
Future<({String? result, Object? error, int commits})> _call({
  required int maxAttempts,
  RpcRetryPredicate? retryOn,
}) async {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Svc());
  responder.start();

  caller.addInterceptor(
    RpcRetryInterceptor(
      maxAttempts: maxAttempts,
      retryOn: retryOn,
      backoff: const ExponentialBackoff(
        baseDelay: Duration(milliseconds: 5),
        maxDelay: Duration(milliseconds: 15),
      ),
    ),
  );

  String? result;
  Object? error;
  try {
    final r = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'charge',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    result = r.value;
  } catch (e) {
    error = e;
  }

  await caller.close();
  await responder.close();
  return (result: result, error: error, commits: _commits);
}

void main() {
  setUp(() {
    _commits = 0;
    _loseAfterCommit = 0;
    _appErrorsBeforeCommit = 0;
  });

  group('what the default predicate actually guarantees', () {
    // GUARD: this is the real guarantee, and the one worth defending. An
    // application error must never cause a second execution.
    test('an application error is never retried', () async {
      _appErrorsBeforeCommit = 5;
      final r = await _call(maxAttempts: 3);

      expect(r.result, isNull, reason: 'the call should have failed');
      expect(
        r.commits,
        0,
        reason: 'an INTERNAL failure was retried into ${r.commits} commit(s)',
      );
      // Two of the five scripted failures must remain unconsumed: exactly one
      // attempt may have run.
      expect(
        _appErrorsBeforeCommit,
        4,
        reason: 'the handler ran ${5 - _appErrorsBeforeCommit} times, not once',
      );
    });

    // CHARACTERIZATION: the documented trade-off. If this ever starts failing,
    // the default predicate changed and the class doc must change with it.
    test('UNAVAILABLE after a commit re-issues the commit', () async {
      _loseAfterCommit = 1;
      final r = await _call(maxAttempts: 3);

      expect(
        r.commits,
        2,
        reason:
            'expected the documented duplication: one lost response should '
            'produce a second commit',
      );
      expect(
        r.result,
        'charged',
        reason:
            'and the caller is handed a success, so it cannot tell the write '
            'happened twice',
      );
    });

    // GUARD: the escape hatch the class doc points at must work, or the advice
    // is empty.
    test('a custom retryOn can exclude UNAVAILABLE', () async {
      _loseAfterCommit = 1;
      final r = await _call(
        maxAttempts: 3,
        // Retry only local rate-limit rejections, never a lost response.
        retryOn: (e) => e is RpcRateLimitException,
      );

      expect(
        r.commits,
        1,
        reason: 'the custom predicate still allowed ${r.commits} commits',
      );
      expect(r.result, isNull);
      expect(r.error, isA<RpcStatusException>());
    });

    // GUARD: the ordinary path is untouched.
    test('a call that succeeds first time commits once', () async {
      final r = await _call(maxAttempts: 3);
      expect(r.result, 'charged');
      expect(r.commits, 1);
    });
  });
}
