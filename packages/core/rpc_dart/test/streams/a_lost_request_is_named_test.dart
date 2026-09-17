// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request message vanishing between the peer and the handler used to be
// silent: the caller was told the call succeeded over a sequence the handler
// never saw, and both sides reported success over different data. That is how a
// consumer's upload came to acknowledge 16 of the 17 messages it was sent with
// no error anywhere, and it is why B-44 could not be diagnosed from either end —
// the caller knows what it sent, the handler knows what it read, and nothing
// compared the two.
//
// The pipeline now compares them as the call ends, and says so. It does not
// fail the call: by then the answer has gone out and there is nobody left to
// report to. What it buys is that the next occurrence is one grep away instead
// of unfalsifiable.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Upload extends RpcResponderContract {
  _Upload() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'put',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
        }
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Throws part-way: the call ends by error while frames are still arriving.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'putThrows',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
          if (n == 3) throw StateError('handler died');
        }
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Never finishes: used for the deadline and cancellation endings.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'putForever',
      handler: (reqs, {RpcContext? context}) async {
        await for (final _ in reqs) {}
        await Completer<void>().future;
        return 'x'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    // Reads three and returns — legal, and round 375 recorded it as deliberate.
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'putShort',
      handler: (reqs, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in reqs) {
          n++;
          if (n == 3) break;
        }
        return '$n'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Stream<RpcString> _chunks(int n) async* {
  for (var i = 0; i < n; i++) {
    yield '$i'.rpc;
  }
}

void main() {
  test('GUARD: a healthy upload says nothing', () async {
    // The check must be silent on every ordinary call, or it is noise — the
    // failure mode B-45 was filed for.
    final logs = LogController(minLevel: RpcLogLevel.warning);
    final errors = <LogEvent>[];
    logs.stream.listen((r) {
      if (r is LogEvent && r.level == RpcLogLevel.error) errors.add(r);
    });

    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server, logger: logs);
    responder.registerServiceContract(_Upload());
    responder.start();

    final answered = await caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'put',
      requestCodec: _codec,
      responseCodec: _codec,
    )(_chunks(17));

    await Future<void>.delayed(const Duration(milliseconds: 200));

    // Asserted FIRST: the log line is this test's subject, and a delivery
    // assertion ahead of it would fail on the same canary and hide whether the
    // detector spoke at all.
    expect(
      errors.where((e) => e.message.contains('LOST')).map((e) => e.message),
      isEmpty,
      reason: 'an ordinary 17-chunk upload reported a loss',
    );
    expect(answered.value, '17', reason: 'the handler should see all 17');

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('GUARD: a handler that stops reading early is not a loss', () async {
    // The dangerous false positive. A client-stream handler may legitimately
    // read three of seventeen and return — round 375 recorded that as
    // deliberate — and the pipeline then has frames it accepted and did not
    // deliver. Calling that "LOST" would make the detector fire on an ordinary
    // pattern, which is the failure B-45 was filed for: 704 warnings a day
    // drowning the one line that mattered.
    final logs = LogController(minLevel: RpcLogLevel.warning);
    final errors = <LogEvent>[];
    logs.stream.listen((r) {
      if (r is LogEvent && r.level == RpcLogLevel.error) errors.add(r);
    });

    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server, logger: logs);
    responder.registerServiceContract(_Upload());
    responder.start();

    await caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'putShort',
      requestCodec: _codec,
      responseCodec: _codec,
    )(_chunks(17));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      errors.where((e) => e.message.contains('LOST')).map((e) => e.message),
      isEmpty,
      reason: 'a handler that stopped reading early was reported as a loss',
    );

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  group('GUARD: the detector is silent on every other ending', () {
    // Round 372 enumerated seven ways a call can end. A detector that fires on
    // any of them is noise, and noise is what B-45 was filed for — so each is
    // driven here rather than reasoned about. The two already covered above are
    // the healthy call and the early return.
    Future<List<String>> drive(
      Future<void> Function(RpcCallerEndpoint, RpcChannelTransport) body,
    ) async {
      final logs = LogController(minLevel: RpcLogLevel.warning);
      final errors = <LogEvent>[];
      logs.stream.listen((r) {
        if (r is LogEvent && r.level == RpcLogLevel.error) errors.add(r);
      });

      final (client, server) = RpcChannelTransport.pair();
      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server, logger: logs);
      responder.registerServiceContract(_Upload());
      responder.start();

      await body(caller, server);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      await caller.close().catchError((_) {});
      await responder.close().catchError((_) {});
      await client.close().catchError((_) {});
      await server.close().catchError((_) {});
      return errors
          .where((e) => e.message.contains('LOST'))
          .map((e) => e.message)
          .toList();
    }

    Future<void> upload(
      RpcCallerEndpoint caller,
      String method, {
      RpcContext? context,
    }) async {
      try {
        await caller
            .clientStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: method,
              requestCodec: _codec,
              responseCodec: _codec,
              context: context,
            )(_chunks(17))
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    test('the handler throws part-way', () async {
      expect(await drive((c, _) => upload(c, 'putThrows')), isEmpty);
    });

    test('the deadline expires mid-upload', () async {
      expect(
        await drive(
          (c, _) => upload(
            c,
            'putForever',
            context: RpcContext.withTimeout(const Duration(milliseconds: 200)),
          ),
        ),
        isEmpty,
      );
    });

    test('the caller cancels mid-upload', () async {
      final token = RpcCancellationToken();
      expect(
        await drive((c, _) async {
          final f = upload(
            c,
            'putForever',
            context: RpcContext.withCancellation(token),
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
          token.cancel('probe');
          await f;
        }),
        isEmpty,
      );
    });

    test('the transport dies mid-upload', () async {
      expect(
        await drive((c, server) async {
          final f = upload(c, 'putForever');
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await server.close();
          await f;
        }),
        isEmpty,
      );
    });
  });

  test('the accepted and delivered counts agree on a healthy call', () async {
    // The check is a comparison of two counters, so the property worth pinning
    // is that they track each other — not the log line, which only appears when
    // they do not. Read through the endpoint's own metrics.
    final (client, server) = RpcChannelTransport.pair();
    final caller = RpcCallerEndpoint(transport: client);
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Upload());
    responder.start();

    final answered = await caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'put',
      requestCodec: _codec,
      responseCodec: _codec,
    )(_chunks(5));
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(answered.value, '5');
    // The stream is gone by now, which is itself the assertion that the
    // comparison ran and found nothing to say.
    expect(responder.collectEndpointMetrics()['openStreams'], 0);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
