// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// An advisory channel error -- one stream's metadata over the policy, a text
// frame on a websocket -- is a discarded frame on a connection that still
// works. Both pipelines treated it as such and then logged it at ERROR, once
// per frame, so the peer chose how many incident-level records the other side
// wrote. Measured over a real websocket, 100 frames each: text frames 100
// errors, over-policy metadata 100 errors; a genuine framing failure 1.

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

import '../support/raw_channel.dart';

final class _Counting extends LogController {
  _Counting() : super(minLevel: RpcLogLevel.debug);

  final warnings = <String>[];
  final errors = <String>[];

  @override
  void add(LogRecord record) {
    if (record is LogEvent) {
      if (record.level == RpcLogLevel.warning) warnings.add(record.message);
      if (record.level == RpcLogLevel.error) errors.add(record.message);
    }
    super.add(record);
  }
}

/// Metadata for [id] with more headers than the default policy admits.
Uint8List _overPolicy(int id) => RpcChannelFrame.encodeMetadata(
  streamId: id,
  metadata: RpcMetadata([
    ...RpcMetadata.forClientRequest('Svc', 'u').headers,
    for (var h = 0; h < 200; h++) RpcHeader('x-h$h', 'v'),
  ], methodPath: '/Svc/u'),
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  test('the responder reports an advisory error once, not per frame', () async {
    // WITNESS. Before: 10 errors "Transport incoming error".
    final log = _Counting();
    final chan = RawPeerChannel();
    final transport = RpcChannelTransport.fromChannel(
      channel: chan,
      isClient: false,
    );
    final responder = RpcResponderEndpoint(
      transport: transport,
      logController: log,
    )..start();
    addTearDown(() async {
      await responder.close();
      await transport.close();
    });

    for (var i = 0; i < 10; i++) {
      chan.feed(_overPolicy(1 + 2 * i));
    }
    await _settle();

    expect(log.errors, isEmpty, reason: '${log.errors}');
    expect(
      log.warnings.where((m) => m.contains('discarded frame')),
      hasLength(1),
      reason: '${log.warnings}',
    );
  });

  test('the caller reports an advisory error once, not per frame', () async {
    // WITNESS. A hostile SERVER does the same to a client.
    final log = _Counting();
    final chan = RawPeerChannel();
    final transport = RpcChannelTransport.fromChannel(
      channel: chan,
      isClient: true,
    );
    final caller = RpcCallerEndpoint(transport: transport, logController: log);
    addTearDown(() async {
      await caller.close();
      await transport.close();
    });

    for (var i = 0; i < 10; i++) {
      chan.feed(_overPolicy(2 + 2 * i));
    }
    await _settle();

    expect(log.errors, isEmpty, reason: '${log.errors}');
    expect(
      log.warnings.where((m) => m.contains('discarded frame')),
      hasLength(1),
      reason: '${log.warnings}',
    );
  });

  test('GUARD: a genuine channel failure is still an error', () async {
    final log = _Counting();
    final chan = RawPeerChannel();
    final transport = RpcChannelTransport.fromChannel(
      channel: chan,
      isClient: false,
    );
    final responder = RpcResponderEndpoint(
      transport: transport,
      logController: log,
    )..start();
    addTearDown(() async {
      await responder.close();
      await transport.close();
    });

    // An error from the channel itself, which carries no advisory marker.
    chan.fail(StateError('socket broke'));
    await _settle();

    expect(log.errors, contains('Transport incoming error'));
  });
}
