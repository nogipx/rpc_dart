// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The unary responder assumed one transport message carries one whole gRPC frame.
// Split each frame in two and unary answered INTERNAL "Failed to extract message
// from payload" while both streaming shapes, sharing the same transport, channel,
// codec and payload, answered normally.
//
// Three things have to hold together, and any two without the third are worse than
// none: the responder waits for the rest of a frame, later fragments are routed to
// it, and a peer that half-closes mid-frame is ANSWERED. Waiting without the answer
// is a hang, which is worse than the error being fixed.
//
// What makes the waiting safe is asking the PARSER whether it holds a partial frame.
// An empty parse result also means REFUSED — every limit in the parser clears its
// buffer and throws — so inferring "incomplete" from emptiness turns a
// `maxMessageLengthBytes` refusal into a truncation report. The refusal guard below
// is that distinction, and it is the arm that must never go green by accident.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Splits every DATA frame in two, which is what a transport forwarding raw
/// chunks produces. No shipped transport does — http2 reassembles with a
/// per-stream `RpcMessageParser`, the frame channel reassembles, and HTTP/1.1
/// buffers the whole body — so this has to be built.
final class _Fragmenting implements IRpcChannel {
  _Fragmenting({
    required this.split,
    this.truncate = false,
    this.lateEnd = false,
  });

  final bool split;

  /// Send only the first half and half-close: the peer that stops mid-frame.
  final bool truncate;

  /// Half-close in a SEPARATE, LATER frame rather than on the fragment itself.
  ///
  /// A different ordering, and the two are answered by different code. With the
  /// half-close on the fragment, the pipeline already knows the peer has finished
  /// by the time it dispatches the responder. Arriving later, it has to reach a
  /// responder that is already waiting — which nothing else covers.
  final bool lateEnd;

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
        endOfStream: truncate && !lateEnd,
      ),
    );
    if (truncate) {
      if (lateEnd) {
        // After the responder has had its turn to start waiting.
        // A BARE half-close, carrying no data. A frame with an empty payload is
        // still a data frame and reaches the fragment router, which answers it
        // for its own reasons; this one can only be seen by the end-of-stream
        // path.
        Future<void>.delayed(const Duration(milliseconds: 50), () {
          _deliver(RpcChannelFrame.encodeEndOfStream(streamId));
        });
      }
      return;
    }
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
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'collect',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        return 'got:$n'.rpc;
      },
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echoes',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {context}) async* {
        await for (final r in requests) {
          yield 'got:${r.value.length}'.rpc;
        }
      },
    );
  }
}

/// A caller and responder over a channel with the given behaviour.
///
/// The RESPONDER's policy is the side under test wherever one is passed; the
/// caller keeps the defaults, so it sends what its peer will refuse.
RpcCallerEndpoint _rig({
  required bool split,
  bool truncate = false,
  bool lateEnd = false,
  RpcSecurityPolicy? responderPolicy,
}) {
  final client = _Fragmenting(
    split: split,
    truncate: truncate,
    lateEnd: lateEnd,
  );
  final server = _Fragmenting(split: split);
  client.peer = server;
  server.peer = client;

  final responder =
      RpcResponderEndpoint(
          transport: RpcChannelTransport(
            channel: RpcFrameMultiplexedChannel(channel: server),
            isClient: false,
            policy: responderPolicy ?? const RpcSecurityPolicy(),
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
  return caller;
}

/// The outcome of a SERVER-stream call over a channel with the given behaviour.
Future<String> _serverStream({
  required bool split,
  bool truncate = false,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final caller = _rig(split: split, truncate: truncate);
  try {
    final got = await caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'tick',
          request: ('x' * 64).rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(timeout),
        )
        .toList();
    return got.map((e) => e.value).join(',');
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}: ${e.message}';
  }
}

/// The outcome of a CLIENT-stream call over a channel with the given behaviour.
Future<String> _clientStream({
  required bool split,
  bool truncate = false,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final caller = _rig(split: split, truncate: truncate);
  try {
    final call = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'collect',
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.empty().withTimeout(timeout),
    );
    final reply = await call(Stream.value(('x' * 64).rpc));
    return reply.value;
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}: ${e.message}';
  }
}

/// The outcome of a BIDI call over a channel with the given behaviour.
Future<String> _bidi({
  required bool split,
  bool truncate = false,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final caller = _rig(split: split, truncate: truncate);
  try {
    final got = await caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echoes',
          requests: Stream.value(('x' * 64).rpc),
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.empty().withTimeout(timeout),
        )
        .toList();
    return got.map((e) => e.value).join(',');
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}: ${e.message}';
  }
}

/// The outcome of one unary call over a channel with the given behaviour.
Future<String> _unary({
  required bool split,
  bool truncate = false,
  bool lateEnd = false,
  int requestBytes = 64,
  RpcSecurityPolicy? responderPolicy,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final caller = _rig(
    split: split,
    truncate: truncate,
    lateEnd: lateEnd,
    responderPolicy: responderPolicy,
  );

  try {
    final reply = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: ('x' * requestBytes).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.empty().withTimeout(timeout),
    );
    return reply.value;
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}: ${e.message}';
  }
}

void main() {
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
  );

  test(
    'a peer that stops mid-frame gets a STATUS, not a hang',
    () async {
      // The failure the fix can introduce, and the reason round 518's partial
      // version was reverted. INVALID_ARGUMENT names the malformed request;
      // DEADLINE_EXCEEDED (status 4) would mean the call was left waiting.
      expect(
        await _unary(split: true, truncate: true),
        startsWith('status ${RpcStatus.invalidArgument}'),
        reason: 'an incomplete frame that is merely awaited is a hang',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a LATE half-close mid-frame also gets a status',
    () async {
      // Same failure, different ordering, and a different branch answers it: here
      // the pipeline has already dispatched a waiting responder when the
      // half-close arrives. With the fragment carrying its own end-of-stream the
      // dispatch sees `clientEnded` and answers there instead, so that arm cannot
      // see this one.
      expect(
        await _unary(split: true, truncate: true, lateEnd: true),
        startsWith('status ${RpcStatus.invalidArgument}'),
        reason: 'a request left incomplete must be answered, not awaited',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // One pipeline, three shapes, and each used to give the peer a different ending
  // on the same input: unary a status, a server stream its deadline, a client
  // stream a SUCCESS reporting zero messages where the peer had sent an
  // incomplete one. Separate tests, because the two failures are different and a
  // single test stops at whichever assertion fails first.

  test(
    'WITNESS a server stream answers a mid-frame half-close',
    () async {
      expect(
        await _serverStream(split: true, truncate: true),
        startsWith('status ${RpcStatus.invalidArgument}'),
        reason:
            'a server stream carries exactly one request, so without this the '
            'handler never runs and the call waits out its deadline',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS a client stream does not report a truncated request as empty',
    () async {
      expect(
        await _clientStream(split: true, truncate: true),
        startsWith('status ${RpcStatus.invalidArgument}'),
        reason:
            'got:0 tells the handler the peer sent nothing, where in fact it '
            'sent an incomplete something — and the call SUCCEEDS',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS a bidi stream answers a mid-frame half-close',
    () async {
      // The same StreamProcessor path as the two shapes above, so fixed by
      // construction; this is what measures it.
      expect(
        await _bidi(split: true, truncate: true),
        startsWith('status ${RpcStatus.invalidArgument}'),
        reason: 'an incomplete frame followed by a half-close must be answered',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD a fragmented bidi request still works',
    () async {
      expect(await _bidi(split: false), 'got:64');
      expect(await _bidi(split: true), 'got:64');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('GUARD whole frames still work', () async {
    expect(await _unary(split: false), 'got:64');
    expect(await _serverStream(split: false), 'got:64');
    expect(await _clientStream(split: false), 'got:1');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'GUARD a fragmented request still works on every shape',
    () async {
      // The other direction of the same rule: holding a partial frame must not
      // leak into a call whose frames do arrive, just in pieces.
      expect(await _unary(split: true), 'got:64');
      expect(await _serverStream(split: true), 'got:64');
      expect(await _clientStream(split: true), 'got:1');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD a REFUSED frame is not reported as a truncated one',
    () async {
      // The arm that reverted attempt 2. A frame the parser refuses yields no
      // messages, exactly like an incomplete one — so an implementation reading
      // emptiness as "incomplete" answers INVALID_ARGUMENT "closed mid-message"
      // where the operator's limit fired, and the status no longer names what
      // refused it.
      final answer = await _unary(
        split: true,
        requestBytes: 64 * 1024,
        responderPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
      );

      expect(
        answer,
        startsWith('status ${RpcStatus.resourceExhausted}'),
        reason:
            'the request is past maxMessageLengthBytes, which is a refusal and '
            'not a truncation',
      );
      expect(
        answer,
        contains('max:'),
        reason:
            'a resource limit must name the limit it enforced — the number is '
            'the buffer bound derived from maxMessageLengthBytes, not that '
            'field verbatim',
      );
      expect(
        answer,
        isNot(contains('mid-message')),
        reason:
            'this is the wrong answer attempt 2 gave: a refusal reported as a '
            'truncation',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

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
