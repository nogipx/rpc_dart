// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The unary responder assumed one transport message carries one whole gRPC frame.
// Split each frame in two and unary answered INTERNAL "Failed to extract message
// from payload" while both streaming shapes, sharing the same transport, channel,
// codec and payload, answered normally.
//
// Round 518 fixed the parser half alone and REVERTED it: the later fragment had no
// route, so an immediate INTERNAL became a hang, and a hang is worse than the error.
// Round 547 built all three parts, got both arms passing, and REVERTED AGAIN — for a
// reason neither earlier attempt had reached, stated in the skips below.
//
// The two witnesses are kept SKIPPED rather than deleted: they are the arms a third
// attempt needs, and re-deriving them costs more than reading them. The two guards
// describe behaviour that holds today and run.
//
// The measurements are in `.claude/loop/rounds/547`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Splits every DATA frame in two, which is what a transport forwarding raw
/// chunks produces. No shipped transport does — http2 reassembles with a
/// per-stream `RpcMessageParser`, the frame channel reassembles, and HTTP/1.1
/// buffers the whole body — so this has to be built.
final class _Fragmenting implements IRpcChannel {
  _Fragmenting({required this.split, this.truncate = false});

  final bool split;

  /// Send only the first half and half-close: the peer that stops mid-frame.
  final bool truncate;

  final _ctl = StreamController<Uint8List>();
  late _Fragmenting peer;

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {
    final view = ByteData.sublistView(data);
    final streamId = view.getUint32(0);
    final flags = view.getUint8(4);
    final len = view.getUint32(5);
    final isData = (flags & RpcChannelFrame.flagMetadata) == 0 && len > 4;

    if (!split || !isData) {
      _deliver(data);
      return;
    }

    final payload = Uint8List.sublistView(
      data,
      RpcChannelFrame.headerSize,
      RpcChannelFrame.headerSize + len,
    );
    final cut = len ~/ 2;
    final endOfStream = (flags & ~RpcChannelFrame.flagMetadata) != 0;
    _deliver(
      RpcChannelFrame.encodeData(
        streamId: streamId,
        payload: Uint8List.sublistView(payload, 0, cut),
        endOfStream: truncate,
      ),
    );
    if (truncate) return;
    _deliver(
      RpcChannelFrame.encodeData(
        streamId: streamId,
        payload: Uint8List.sublistView(payload, cut),
        endOfStream: endOfStream,
      ),
    );
  }

  void _deliver(Uint8List bytes) {
    if (!peer._ctl.isClosed) peer._ctl.add(bytes);
  }

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'got:${req.value.length}'.rpc,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'tick',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async* {
        yield 'got:${req.value.length}'.rpc;
      },
    );
  }
}

/// The outcome of one unary call over a channel with the given behaviour.
Future<String> _unary({
  required bool split,
  bool truncate = false,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = _Fragmenting(split: split, truncate: truncate);
  final server = _Fragmenting(split: split);
  client.peer = server;
  server.peer = client;

  final responder =
      RpcResponderEndpoint(
          transport: RpcChannelTransport(
            channel: RpcFrameMultiplexedChannel(channel: server),
            isClient: false,
          ),
        )
        ..registerServiceContract(_Svc())
        ..start();
  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(
        channel: client,
        closeOnOversizedFrame: false,
      ),
      isClient: true,
    ),
  );
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  try {
    final reply = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: ('x' * 64).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.empty().withTimeout(timeout),
    );
    return reply.value;
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  }
}

void main() {
  // SKIPPED, and the condition is precise: an implementation may only wait for the
  // rest of a frame when it can tell "incomplete" from "refused". Round 547's did
  // not — it read `RpcMessageParser` returning NO messages as "incomplete", and a
  // frame the parser REFUSES for exceeding `maxMessageLengthBytes` returns nothing
  // too. A 32 MB compressed payload against a 1 MB policy then answered
  // INVALID_ARGUMENT "closed mid-message" instead of RESOURCE_EXHAUSTED naming the
  // operator's limit, which is a security control reporting the wrong thing.
  //
  // So a third attempt has to get the distinction FROM the parser — it knows
  // whether it is holding a partial frame — and not from the emptiness of its
  // result. Unskip these two when it can.
  const blocked =
      'B-126: needs the parser to distinguish an INCOMPLETE frame from a '
      'REFUSED one; round 547 inferred it from an empty result and broke the '
      'maxMessageLengthBytes refusal (see rounds/547)';

  test(
    'WITNESS a fragmented request is answered',
    () async {
      expect(
        await _unary(split: true),
        'got:64',
        reason:
            'one transport message carried half a gRPC frame, and unary claimed '
            'the request before parsing it',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: blocked,
  );

  test(
    'a peer that stops mid-frame gets a STATUS, not a hang',
    () async {
      // The failure the fix can introduce, and the reason round 518's partial
      // version was reverted. INVALID_ARGUMENT names the malformed request;
      // DEADLINE_EXCEEDED (status 4) would mean the call was left waiting.
      expect(
        await _unary(split: true, truncate: true),
        'status ${RpcStatus.invalidArgument}',
        reason: 'an incomplete frame that is merely awaited is a hang',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
    skip: blocked,
  );

  test('GUARD whole frames still work', () async {
    expect(await _unary(split: false), 'got:64');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'GUARD the streaming shapes are unaffected',
    () async {
      // This is what makes the skipped witness a statement about UNARY: the same
      // rig, the same fragmenting channel, and the streaming shapes answer. Any
      // third attempt must keep this row passing.
      final client = _Fragmenting(split: true);
      final server = _Fragmenting(split: true);
      client.peer = server;
      server.peer = client;

      final responder =
          RpcResponderEndpoint(
              transport: RpcChannelTransport(
                channel: RpcFrameMultiplexedChannel(channel: server),
                isClient: false,
              ),
            )
            ..registerServiceContract(_Svc())
            ..start();
      final caller = RpcCallerEndpoint(
        transport: RpcChannelTransport(
          channel: RpcFrameMultiplexedChannel(
            channel: client,
            closeOnOversizedFrame: false,
          ),
          isClient: true,
        ),
      );
      addTearDown(() async {
        await caller.close();
        await responder.close();
      });

      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'tick',
            request: ('x' * 64).rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.empty().withTimeout(const Duration(seconds: 3)),
          )
          .toList();

      expect(got.map((e) => e.value), ['got:64']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
