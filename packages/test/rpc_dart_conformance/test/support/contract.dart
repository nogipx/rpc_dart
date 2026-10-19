// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The one contract every row calls: four methods, one per call shape, over one
// message type. Hand-written with the core API; this package runs no
// build_runner.
//
// The handler reports what happens to it through a [ProbeEmit] the caller
// gives it -- an event at the PEER (L-11), never a gauge the test polls. In
// process it records straight into a `Probe`; in an isolate it posts to a
// SendPort that feeds the same `Probe` on the host.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import 'calls.dart' show CallShape;

/// Wire name of the conformance service.
const conformanceService = 'Conformance';

/// Header a caller sets to make a streaming handler wait this many
/// milliseconds before it reads its first request: the server side of a
/// "paused receiver".
const pauseReadHeader = 'x-conformance-pause-ms';

/// Reports one event from inside a handler: what happened, to which call, and
/// a number whose meaning depends on the event.
typedef ProbeEmit = void Function(String kind, int id, int n);

/// What a handler does after it has started.
enum Mode {
  /// Answer at once (after `delayMs`, if set).
  echo,

  /// Never answer. End only when the call is cancelled or expires.
  hang,

  /// Wait `delayMs`, then answer.
  hold,

  /// Wait `delayMs`, then fail with ABORTED.
  fail,

  /// Server stream: emit `count` responses, reporting each one that the
  /// response pipeline accepted.
  produce,
}

/// The one message type: a fixed header, then filler up to the size the
/// caller chose. The size of the whole serialized message is the size the
/// policy limits measure.
final class Blob {
  Blob(this.bytes);

  /// Magic, id, mode, responseSize, count, delayMs.
  static const headerSize = 24;
  static const _magic = 0x52504343; // 'RPCC'

  /// The largest response a request may ask for. A request decoded from
  /// garbage must not make the handler allocate gigabytes.
  static const maxResponseSize = 32 * 1024 * 1024;

  final Uint8List bytes;

  /// A request of exactly [size] bytes (at least [headerSize]).
  factory Blob.request({
    required int id,
    Mode mode = Mode.echo,
    int responseSize = headerSize,
    int count = 1,
    int delayMs = 0,
    int size = headerSize,
  }) {
    final bytes = Uint8List(size < headerSize ? headerSize : size);
    ByteData.sublistView(bytes)
      ..setUint32(0, _magic)
      ..setUint32(4, id)
      ..setUint32(8, mode.index)
      ..setUint32(12, responseSize)
      ..setUint32(16, count)
      ..setUint32(20, delayMs);
    return Blob(bytes);
  }

  /// A response to call [id] of exactly [size] bytes.
  factory Blob.response(int id, int size) =>
      Blob.request(id: id, size: size, responseSize: 0);

  /// Decodes [bytes], refusing anything that is not a [Blob]. Garbage from a
  /// hostile peer fails here, which is what a real codec does.
  factory Blob.decode(Uint8List bytes) {
    if (bytes.length < headerSize ||
        ByteData.sublistView(bytes).getUint32(0) != _magic) {
      throw const FormatException('not a conformance Blob');
    }
    final blob = Blob(bytes);
    if (blob.mode == null) throw const FormatException('unknown mode');
    if (blob.responseSize > maxResponseSize) {
      throw const FormatException('response size out of range');
    }
    return blob;
  }

  ByteData get _view => ByteData.sublistView(bytes);

  int get id => _view.getUint32(4);
  Mode? get mode {
    final i = _view.getUint32(8);
    return i < Mode.values.length ? Mode.values[i] : null;
  }

  int get responseSize => _view.getUint32(12);
  int get count => _view.getUint32(16);
  int get delayMs => _view.getUint32(20);
  int get length => bytes.length;
}

/// The codec both sides use. Serialization is forced on every transport
/// ([RpcDataTransferMode.codec]), so a byte limit means the same thing on all
/// of them -- the isolate transport would otherwise pass unary objects by
/// reference.
final blobCodec = RpcBinaryCodec<Blob>(
  toBytes: (b) => b.bytes,
  fromBytes: Blob.decode,
);

/// A message the core's CBOR codec decodes: an id, how many items to answer
/// with, and a list of empty maps. Each empty map is one byte on the wire and
/// one decoded item, so `items` sets what a message decodes to.
final class Doc implements IRpcSerializable {
  Doc(this.json);

  /// A request carrying [items] empty maps that asks for [reply] in return.
  factory Doc.request({required int id, required int items, int reply = 0}) =>
      Doc({'id': id, 'reply': reply, 'items': _emptyMaps(items)});

  /// A response to call [id] carrying [items] empty maps.
  factory Doc.response(int id, int items) =>
      Doc({'id': id, 'items': _emptyMaps(items)});

  /// Decoded items of a request besides the list's elements: the top map,
  /// its three keys and values (the list counts as one).
  static const requestOverhead = 7;

  /// The same for a response, which has no `reply`.
  static const responseOverhead = 5;

  final Map<String, dynamic> json;

  @override
  Map<String, dynamic> toJson() => json;

  int get id => json['id'] as int;
  int get reply => json['reply'] as int? ?? 0;
  int get items => (json['items'] as List).length;

  static List<Map<String, dynamic>> _emptyMaps(int n) =>
      List.filled(n, const <String, dynamic>{});
}

/// The codec I-8's rows use: the core's own CBOR codec, which is what a
/// generated contract decodes with.
final docCodec = RpcCodec<Doc>.withDecoder(Doc.new);

/// The responder half.
final class ConformanceResponder extends RpcResponderContract {
  ConformanceResponder(this._emit)
    : super(conformanceService, dataTransferMode: RpcDataTransferMode.codec);

  final ProbeEmit _emit;

  @override
  void setup() {
    addUnaryMethod<Blob, Blob>(
      methodName: 'unary',
      handler: _unary,
      requestCodec: blobCodec,
      responseCodec: blobCodec,
    );
    addClientStreamMethod<Blob, Blob>(
      methodName: 'clientStream',
      handler: _clientStream,
      requestCodec: blobCodec,
      responseCodec: blobCodec,
    );
    addServerStreamMethod<Blob, Blob>(
      methodName: 'serverStream',
      handler: _serverStream,
      requestCodec: blobCodec,
      responseCodec: blobCodec,
    );
    addBidirectionalMethod<Blob, Blob>(
      methodName: 'bidi',
      handler: _bidi,
      requestCodec: blobCodec,
      responseCodec: blobCodec,
    );

    // The same four shapes over CBOR. Each reports `received` with the item
    // count of every request it decodes, and answers `reply` items.
    addUnaryMethod<Doc, Doc>(
      methodName: 'cborUnary',
      handler: (r, {RpcContext? context}) async => _answerDoc(r),
      requestCodec: docCodec,
      responseCodec: docCodec,
    );
    addClientStreamMethod<Doc, Doc>(
      methodName: 'cborClientStream',
      handler: (requests, {RpcContext? context}) async {
        Doc? last;
        await for (final r in requests) {
          last = _answerDoc(r);
        }
        if (last == null) {
          throw RpcStatusException(RpcStatus.invalidArgument, 'no request');
        }
        return last;
      },
      requestCodec: docCodec,
      responseCodec: docCodec,
    );
    addServerStreamMethod<Doc, Doc>(
      methodName: 'cborServerStream',
      handler: (r, {RpcContext? context}) => Stream.value(_answerDoc(r)),
      requestCodec: docCodec,
      responseCodec: docCodec,
    );
    addBidirectionalMethod<Doc, Doc>(
      methodName: 'cborBidi',
      handler: (requests, {RpcContext? context}) => requests.map(_answerDoc),
      requestCodec: docCodec,
      responseCodec: docCodec,
    );
  }

  Doc _answerDoc(Doc request) {
    _emit('received', request.id, request.items);
    return Doc.response(request.id, request.reply);
  }

  /// Records `enter`, and arranges `cancelled`, `disposed` and
  /// `timerCancelled` for this call. The timer is a resource the handler holds
  /// through its call scope, so its release is observable.
  void _track(int id, RpcContext? context) {
    _emit('enter', id, 0);
    final token = context?.cancellationToken;
    if (token != null) {
      token.cancelled.then((_) => _emit('cancelled', id, 0)).ignore();
    }
    final scope = context?.callScope;
    if (scope != null) {
      scope.onDispose(() => _emit('disposed', id, 0));
      scope.use(Timer(const Duration(hours: 1), () {}), (Timer t) {
        t.cancel();
        _emit('timerCancelled', id, 0);
      });
    }
  }

  /// Completes when [context]'s call is cancelled or expires, never otherwise.
  Future<void> _ended(RpcContext? context) {
    final token = context?.cancellationToken;
    return token == null ? Completer<void>().future : token.cancelled;
  }

  /// Waits [ms], ending early (with CANCELLED) if the call ends first.
  Future<void> _wait(int ms, RpcContext? context) async {
    if (ms <= 0) return;
    var ended = false;
    await Future.any([
      Future<void>.delayed(Duration(milliseconds: ms)),
      _ended(context).then((_) => ended = true),
    ]);
    if (ended) throw RpcStatusException(RpcStatus.cancelled, 'call ended');
  }

  Future<void> _behave(Blob request, RpcContext? context) async {
    switch (request.mode) {
      case Mode.hang:
        await _ended(context);
        throw RpcStatusException(RpcStatus.cancelled, 'call ended');
      case Mode.fail:
        await _wait(request.delayMs, context);
        // A responseSize past the header pads the message, so a caller
        // chooses what the failure weighs on the wire.
        final pad = request.responseSize - Blob.headerSize;
        throw RpcStatusException(
          RpcStatus.aborted,
          pad > 0 ? 'failed on purpose ${'x' * pad}' : 'failed on purpose',
        );
      case Mode.echo:
      case Mode.hold:
      case Mode.produce:
      case null:
        await _wait(request.delayMs, context);
    }
  }

  Future<void> _pauseBeforeReading(RpcContext? context) async {
    final ms = int.tryParse(context?.getHeader(pauseReadHeader) ?? '') ?? 0;
    if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
  }

  Future<Blob> _unary(Blob request, {RpcContext? context}) async {
    _track(request.id, context);
    _emit('received', request.id, request.length);
    await _behave(request, context);
    return Blob.response(request.id, request.responseSize);
  }

  Future<Blob> _clientStream(
    Stream<Blob> requests, {
    RpcContext? context,
  }) async {
    await _pauseBeforeReading(context);
    Blob? first;
    await for (final r in requests) {
      if (first == null) {
        first = r;
        _track(r.id, context);
      }
      _emit('received', r.id, r.length);
    }
    if (first == null) {
      throw RpcStatusException(RpcStatus.invalidArgument, 'no request');
    }
    await _behave(first, context);
    return Blob.response(first.id, first.responseSize);
  }

  Stream<Blob> _serverStream(Blob request, {RpcContext? context}) async* {
    _track(request.id, context);
    _emit('received', request.id, request.length);
    await _behave(request, context);
    for (var i = 0; i < request.count; i++) {
      yield Blob.response(request.id, request.responseSize);
      if (request.mode == Mode.produce) _emit('produced', request.id, i + 1);
    }
  }

  Stream<Blob> _bidi(Stream<Blob> requests, {RpcContext? context}) async* {
    await _pauseBeforeReading(context);
    var first = true;
    await for (final r in requests) {
      if (first) {
        first = false;
        _track(r.id, context);
        await _behave(r, context);
      }
      _emit('received', r.id, r.length);
      for (var i = 0; i < r.count; i++) {
        yield Blob.response(r.id, r.responseSize);
      }
    }
  }
}

/// The caller half.
final class ConformanceCaller extends RpcCallerContract {
  ConformanceCaller(RpcCallerEndpoint endpoint)
    : super(
        conformanceService,
        endpoint,
        dataTransferMode: RpcDataTransferMode.codec,
      );

  Future<Blob> unary(Blob request, {RpcContext? context}) =>
      callUnary<Blob, Blob>(
        methodName: 'unary',
        request: request,
        requestCodec: blobCodec,
        responseCodec: blobCodec,
        context: context,
      );

  Future<Blob> clientStream(Stream<Blob> requests, {RpcContext? context}) =>
      callClientStream<Blob, Blob>(
        methodName: 'clientStream',
        requests: requests,
        requestCodec: blobCodec,
        responseCodec: blobCodec,
        context: context,
      );

  Stream<Blob> serverStream(Blob request, {RpcContext? context}) =>
      callServerStream<Blob, Blob>(
        methodName: 'serverStream',
        request: request,
        requestCodec: blobCodec,
        responseCodec: blobCodec,
        context: context,
      );

  Stream<Blob> bidi(Stream<Blob> requests, {RpcContext? context}) =>
      callBidirectionalStream<Blob, Blob>(
        methodName: 'bidi',
        requests: requests,
        requestCodec: blobCodec,
        responseCodec: blobCodec,
        context: context,
      );

  /// One CBOR call of [shape] sending [request], ending with its responses.
  Future<List<Doc>> cbor(CallShape shape, Doc request) => switch (shape) {
    CallShape.unary => callUnary<Doc, Doc>(
      methodName: 'cborUnary',
      request: request,
      requestCodec: docCodec,
      responseCodec: docCodec,
    ).then((r) => [r]),
    CallShape.clientStream => callClientStream<Doc, Doc>(
      methodName: 'cborClientStream',
      requests: Stream.value(request),
      requestCodec: docCodec,
      responseCodec: docCodec,
    ).then((r) => [r]),
    CallShape.serverStream => callServerStream<Doc, Doc>(
      methodName: 'cborServerStream',
      request: request,
      requestCodec: docCodec,
      responseCodec: docCodec,
    ).toList(),
    CallShape.bidi => callBidirectionalStream<Doc, Doc>(
      methodName: 'cborBidi',
      requests: Stream.value(request),
      requestCodec: docCodec,
      responseCodec: docCodec,
    ).toList(),
  };
}
