// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A refusal a peer can trigger repeatedly warns ONCE per connection (CLAUDE.md):
// the interesting fact is that it happened, not how often. These warned once per
// refused stream, so a peer chose how many lines the server logged.
//
// Counted by overriding `LogController.add`, which runs before filtering.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class _Counting extends LogController {
  _Counting() : super(minLevel: RpcLogLevel.debug);

  final warnings = <String>[];

  @override
  void add(LogRecord record) {
    if (record is LogEvent && record.level == RpcLogLevel.warning) {
      warnings.add(record.message);
    }
    super.add(record);
  }
}

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.hold) : super('Svc');

  final Completer<void> hold;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'park',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async {
        await hold.future;
        return 'ok'.rpc;
      },
    );
  }
}

/// A responder with [policy] and a raw client transport that ignores windows.
({RpcChannelTransport client, _Counting log, Future<void> Function() close})
_rig(RpcSecurityPolicy policy) {
  final log = _Counting();
  final hold = Completer<void>();
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: const RpcSecurityPolicy(
      maxActiveStreams: 100000,
      flowControlWindowBytes: null,
      flowControlConnectionWindowBytes: null,
      initialSendWindowBytes: null,
    ),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: policy,
  );
  final responder = RpcResponderEndpoint(transport: server, logger: log)
    ..registerServiceContract(_Svc(hold))
    ..start();
  return (
    client: client,
    log: log,
    close: () async {
      if (!hold.isCompleted) hold.complete();
      await responder.close();
      await client.close();
      await server.close();
    },
  );
}

final _request = RpcMessageFrame.encode(_codec.serialize('x'.rpc));

/// Opens one parked unary call.
Future<int> _openCall(RpcChannelTransport client) async {
  final id = client.createStream();
  await client.sendMetadata(id, RpcMetadata.forClientRequest('Svc', 'park'));
  await client.sendMessage(id, _request);
  return id;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

int _count(_Counting log, String needle) =>
    log.warnings.where((m) => m.contains(needle)).length;

void main() {
  test('the stream ceiling warns once for five refusals', () async {
    final r = _rig(const RpcSecurityPolicy(maxActiveStreams: 1));
    addTearDown(r.close);
    for (var i = 0; i < 6; i++) {
      await _openCall(r.client);
    }
    await _settle();
    expect(
      _count(r.log, 'concurrent-stream limit'),
      1,
      reason: '${r.log.warnings}',
    );
  });

  test('the handler ceiling warns once for five refusals', () async {
    final r = _rig(const RpcSecurityPolicy(maxConcurrentHandlers: 1));
    addTearDown(r.close);
    for (var i = 0; i < 6; i++) {
      await _openCall(r.client);
    }
    await _settle();
    expect(
      _count(r.log, 'concurrent-handler limit'),
      1,
      reason: '${r.log.warnings}',
    );
  });

  test('the pre-bind refusal warns once for five streams', () async {
    final r = _rig(const RpcSecurityPolicy(maxBufferedMessagesPerStream: 4));
    addTearDown(r.close);
    for (var s = 0; s < 5; s++) {
      final id = await _openCall(r.client);
      await _settle();
      for (var i = 0; i < 8; i++) {
        await r.client.sendMessage(id, _request);
      }
    }
    await _settle();
    expect(
      _count(r.log, 'before its responder'),
      1,
      reason: '${r.log.warnings}',
    );
  });

  test('the pre-method refusal warns once for five streams', () async {
    final r = _rig(const RpcSecurityPolicy(maxMessageLengthBytes: 64));
    addTearDown(r.close);
    final big = RpcMessageFrame.encode(Uint8List(60));
    for (var s = 0; s < 5; s++) {
      // Data with no metadata first: the method is unknown, so it is parked.
      final id = r.client.createStream();
      for (var i = 0; i < 4; i++) {
        await r.client.sendMessage(id, big);
      }
    }
    await _settle();
    expect(_count(r.log, 'no method'), 1, reason: '${r.log.warnings}');
  });

  test('the half-open reclaim warns once for five silent streams', () async {
    final r = _rig(
      const RpcSecurityPolicy(
        halfOpenStreamTimeout: Duration(milliseconds: 100),
      ),
    );
    addTearDown(r.close);
    for (var s = 0; s < 5; s++) {
      final id = r.client.createStream();
      await r.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'park'),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(_count(r.log, 'half-open'), 1, reason: '${r.log.warnings}');
  });
}
