// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// An internal error has two readers with opposite needs, and one `toString()`
// used to serve neither.
//
// In-process the cause IS the answer: a plugin user sent 2450 consecutive
// `Repair failed for <file>: RpcException: Unhandled repository error` lines,
// not one of which named the SqliteException underneath or the statement it
// died on. The cause was captured all along, in `details['cause']` — but every
// caller logs `'...: $e'`, and `RpcException.toString()` prints only the
// message.
//
// Across the wire the cause is nobody's business: table names, SQL text and
// filesystem paths are backend internals, and the remote caller cannot act on
// them anyway.
//
// Both are tested here, together, because they are one decision. Tested over
// the REAL transport rather than by calling the responder directly: the
// property being pinned is what reaches the other side, and a harness that
// stops short of the wire cannot see it.
// ---------------------------------------------------------------------------

void main() {
  group('internal errors carry their cause in-process', () {
    test('VALIDATES THE FIX: toString names the cause', () {
      final error = RpcDataError.internal(
        'Unhandled repository error',
        error: StateError('cannot start a transaction within a transaction'),
      );

      expect(
        error.toString(),
        contains('cannot start a transaction within a transaction'),
        reason:
            'a wrapper that knows the cause and hides it is worse than no '
            'wrapper — this is the line the user reads in their log',
      );
      // The generic half stays: callers and tests match on it.
      expect(error.toString(), contains('Unhandled repository error'));
    });

    test('the cause is reachable as a value, not only as text', () {
      final boom = StateError('boom');
      final error = RpcDataError.internal('wrapped', error: boom);

      expect(error.cause, same(boom));
      // Kept for anyone already reading it.
      expect(error.details?['cause'], contains('boom'));
    });

    test('an error with no cause is unchanged', () {
      final error = RpcDataError.notFound('no such record');

      expect(error.cause, isNull);
      expect(error.toString(), 'RpcException: no such record');
    });

    test('withoutCause keeps details the caller is entitled to', () {
      final error = RpcDataError.conflict(
        'version conflict',
        details: {'expected': 3, 'actual': 4},
      );

      final onWire = error.withoutCause();

      expect(onWire.details, {'expected': 3, 'actual': 4});
      expect(identical(onWire, error), isTrue, reason: 'nothing to strip');
    });

    test('withoutCause strips the cause and keeps the rest', () {
      final error = RpcDataError(
        'internal',
        status: RpcStatus.internal,
        code: 'INTERNAL',
        details: {'cause': 'SqliteException(1)', 'retryable': false},
        cause: StateError('SqliteException(1)'),
      );

      final onWire = error.withoutCause();

      expect(onWire.cause, isNull);
      expect(onWire.details, {'retryable': false});
      expect(onWire.toString(), isNot(contains('SqliteException')));
    });
  });

  group('internal errors lose their cause at the wire', () {
    late IDataRepository repository;
    late DataServiceClient client;
    late DataServiceServer server;
    late List<RpcDataError> reported;

    Future<void> startServer() async {
      reported = [];
      repository = _ThrowingRepository();
      final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'rpc-server',
      );
      final responder = DataServiceResponder(
        repository: repository,
        transferMode: RpcDataTransferMode.zeroCopy,
        onInternalError: reported.add,
      );
      server = DataServiceServer(
        endpoint: endpoint,
        responder: responder,
        repository: repository,
      );
      await server.start();

      final callerEndpoint = RpcCallerEndpoint(
        transport: clientTransport,
        debugLabel: 'rpc-client',
      );
      client = DataServiceClient(
        callerEndpoint,
        DataServiceCaller(
          endpoint: callerEndpoint,
          transferMode: RpcDataTransferMode.zeroCopy,
        ),
      );
    }

    tearDown(() async {
      await client.close();
      await server.close();
      await repository.dispose();
    });

    test('the remote caller is told what failed, not how', () async {
      await startServer();

      Object? caught;
      try {
        await client.create(collection: 'notes', payload: {'title': 'x'});
      } catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught.toString(), contains('Unhandled repository error'));
      expect(
        caught.toString(),
        isNot(contains('users_secret_table')),
        reason:
            'backend internals must not cross the process boundary — the '
            'caller cannot act on them and should not see them',
      );
    });

    test('the host gets the whole error before it is stripped', () async {
      await startServer();

      try {
        await client.create(collection: 'notes', payload: {'title': 'x'});
      } catch (_) {
        // The remote failure is the point; its shape is the test above.
      }

      expect(reported, hasLength(1));
      expect(
        reported.single.toString(),
        contains('users_secret_table'),
        reason:
            'stripping for the wire must not be the same thing as losing it '
            '— before this hook the cause reached neither side',
      );
    });
  });
}

/// Fails with a message that a remote caller must never see.
class _ThrowingRepository implements IDataRepository {
  @override
  Future<DataRecord> create(CreateRecordRequest request) =>
      throw StateError('no such column: users_secret_table.token');

  /// Real, not routed through [noSuchMethod]: teardown calls it, and a fake
  /// that throws on the way out fails the test it already passed.
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
