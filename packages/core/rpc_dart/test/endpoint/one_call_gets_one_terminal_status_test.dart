// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call to an unregistered method was refused once per INBOUND FRAME. The
// responder has three `binding == null` sites — one on the metadata frame, one on
// the data frame, one on the half-close — and each sent a full terminal trailer,
// so one unary call produced three end-of-stream statuses on one stream id.
//
// `_sendGrpcErrorAndCleanup` remembers the id synchronously for exactly this
// reason, but the guard that consults it also required `_respStreams[id] == null`.
// The teardown runs from a detached `finally`, so between the synchronous mark and
// the cleanup the state is still there and every further frame walked past.
//
// Frames are counted at the byte channel, where one `send` is one frame.
//
// The measurements are in `.claude/loop/rounds/510`.

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// One direction of a byte pipe, recording the frames written into it.
final class _Side implements IRpcChannel {
  final _ctl = StreamController<Uint8List>();
  late _Side peer;
  final frames = <String>[];

  @override
  bool get isClosed => _ctl.isClosed;

  @override
  Stream<Uint8List> get incoming => _ctl.stream;

  @override
  Future<void> send(Uint8List data) async {
    final view = ByteData.sublistView(data);
    final flags = view.getUint8(4);
    final len = view.getUint32(5);
    if ((flags & RpcChannelFrame.flagMetadata) != 0 && len > 0) {
      frames.add(
        utf8.decode(
          Uint8List.sublistView(
            data,
            RpcChannelFrame.headerSize,
            RpcChannelFrame.headerSize + len,
          ),
          allowMalformed: true,
        ),
      );
    } else {
      frames.add(len == 0 ? 'EOS' : 'DATA');
    }
    if (!peer._ctl.isClosed) peer._ctl.add(data);
  }

  @override
  Future<void> close() async {
    if (!_ctl.isClosed) await _ctl.close();
  }

  /// Terminal status frames: what a peer keeping stream state would count.
  int get statusFrames => frames.where((f) => f.contains('grpc-status')).length;
}

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ok',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async => 'ok'.rpc,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'boom',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.permissionDenied, 'no'),
    );
  }
}

typedef _Rig = ({_Side fromResponder, Future<String> Function(String) call});

_Rig _rig() {
  final client = _Side();
  final server = _Side();
  client.peer = server;
  server.peer = client;

  final caller = RpcCallerEndpoint(
    transport: RpcChannelTransport(
      channel: RpcFrameMultiplexedChannel(
        channel: client,
        closeOnOversizedFrame: false,
      ),
      isClient: true,
    ),
  );
  final responder =
      RpcResponderEndpoint(
          transport: RpcChannelTransport(
            channel: RpcFrameMultiplexedChannel(channel: server),
            isClient: false,
          ),
        )
        ..registerServiceContract(_Svc())
        ..start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  Future<String> call(String method) async {
    try {
      final r = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: method,
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withTimeout(const Duration(seconds: 5)),
      );
      return r.value;
    } on RpcStatusException catch (e) {
      return 'status ${e.statusCode}';
    }
  }

  return (fromResponder: server, call: call);
}

void main() {
  test(
    'WITNESS: an unregistered method is refused exactly once',
    () async {
      final rig = _rig();
      // One call first, so the connection's own setup frames are not counted.
      await rig.call('ok');
      rig.fromResponder.frames.clear();

      expect(await rig.call('missing'), 'status ${RpcStatus.unimplemented}');

      expect(
        rig.fromResponder.statusFrames,
        1,
        reason:
            'three inbound frames each hit a separate binding==null site, so the '
            'responder sent three end-of-stream trailers on one stream — a '
            'protocol violation anywhere the peer keeps stream state. '
            'Frames were: ${rig.fromResponder.frames}',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  group('GUARD: the ordinary outcomes are unchanged', () {
    test(
      'a successful call still answers, with one status',
      () async {
        final rig = _rig();
        await rig.call('ok');
        rig.fromResponder.frames.clear();

        expect(await rig.call('ok'), 'ok');
        expect(rig.fromResponder.statusFrames, 1);
        expect(rig.fromResponder.frames.any((f) => f == 'DATA'), isTrue);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a handler that throws still answers, with one status',
      () async {
        final rig = _rig();
        await rig.call('ok');
        rig.fromResponder.frames.clear();

        expect(await rig.call('boom'), 'status ${RpcStatus.permissionDenied}');
        expect(rig.fromResponder.statusFrames, 1);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a released stream id is still reusable by a NEW call',
      () async {
        // The condition removed from the guard was `_respStreams[id] == null`. What
        // the guard still has to do is let a genuine new call — metadata WITH a
        // methodPath — reuse an id that has been closed, while ignoring trailing
        // frames that carry neither. Several calls in sequence exercise exactly
        // that, because the caller reuses ids as they are released.
        final rig = _rig();
        for (var i = 0; i < 6; i++) {
          expect(await rig.call('ok'), 'ok', reason: 'call $i');
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'a refused call does not poison the next one on that id',
      () async {
        // The sharpest version of the same risk: refuse, then call again. If the
        // closed-set entry were never cleared, the next call would be ignored and
        // hang to its deadline.
        final rig = _rig();
        expect(await rig.call('missing'), 'status ${RpcStatus.unimplemented}');
        expect(await rig.call('ok'), 'ok');
        expect(await rig.call('missing'), 'status ${RpcStatus.unimplemented}');
        expect(await rig.call('ok'), 'ok');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
