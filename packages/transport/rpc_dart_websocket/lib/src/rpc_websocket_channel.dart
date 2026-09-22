// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// gRPC status for the WebSocket close code the peer hung up with.
///
/// The close code is the only thing a WebSocket peer can say about WHY it went
/// away, and the split matters because UNAVAILABLE is RETRYABLE
/// ([RpcRetryInterceptor] retries it): mapping every close to it retries
/// failures that can never succeed.
///
/// - 1000/1001/1005/1006 and 1012/1013/1014 are CONNECTION-level and transient,
///   so `unavailable`. 1001 and 1012/1013 are the WebSocket analogue of HTTP/2
///   GOAWAY — a shutdown or a draining load balancer.
/// - 1008 policy violation is `permissionDenied`: deterministic.
/// - 1009 message too big is `resourceExhausted`. This one IS retried by the
///   default interceptor and the resend fails identically; set `retryOn` if
///   that matters. The semantically correct code is preferred over hiding it
///   as INTERNAL.
/// - 1002/1003/1007/1010/1011 are protocol or server faults: `internal`, NOT
///   retried.
/// - 3000-4999 are library/application codes with no fixed meaning, so
///   `unknown`. Same rule as `grpcStatusFromHttpStatus`.
int grpcStatusFromWebSocketCloseCode(int? closeCode) => switch (closeCode) {
  null => RpcStatus.unavailable,
  1000 || 1001 || 1005 || 1006 => RpcStatus.unavailable,
  1012 || 1013 || 1014 => RpcStatus.unavailable,
  1008 => RpcStatus.permissionDenied,
  1009 => RpcStatus.resourceExhausted,
  1002 || 1003 || 1007 || 1010 || 1011 => RpcStatus.internal,
  _ => RpcStatus.unknown,
};

/// A non-binary frame on a binary-only protocol.
///
/// Advisory: it says one frame was discarded, not that the connection is gone.
/// Without the marker `RpcChannelTransport` answers it into every per-stream
/// controller, so a single app-level keepalive from a proxy failed every call
/// in flight — with a non-retryable [RpcException], over a connection that was
/// still working.
class RpcWebSocketNonBinaryFrame extends RpcException
    implements IRpcAdvisoryChannelError {
  /// Creates the report for a frame of type [runtimeTypeName].
  RpcWebSocketNonBinaryFrame(String runtimeTypeName)
    : super(
        'RpcWebSocketChannel: expected a binary WebSocket message, got '
        '$runtimeTypeName. This transport is binary-only; a text frame cannot '
        'carry an RPC frame and was discarded.',
      );
}

/// [IRpcChannel] over a [WebSocketChannel]: the WebSocket message stream as a
/// raw byte pipe.
///
/// Combine with [RpcChannelTransport.fromChannel] for a full [IRpcTransport]
/// with multiplexing, security and health checks.
///
/// ```dart
/// final transport = RpcChannelTransport.fromChannel(
///   channel: RpcWebSocketChannel(WebSocketChannel.connect(uri)),
///   isClient: true,
/// );
/// ```
///
/// **Do not close the socket you passed in while calls are in flight — closing
/// it out from under this channel can end the isolate.** `WebSocketSink.add`
/// queues into a `StreamController` and the real send runs a microtask later,
/// in the zone the socket was CONSTRUCTED in. Close the raw socket in the same
/// turn as a send and that send throws `Bad state: StreamSink is closed` there,
/// where no caller can catch it: an unhandled async error, which in the root
/// zone takes the process with it.
///
/// Measured, one variable per row — only the last reaches it:
///
/// ```
/// peer closed, same turn / +1 turn / +50ms      send returned
/// our close() first                             send returned
/// the raw socket, closed behind this channel    send returned
/// the raw socket, closed in the SAME turn       ROOT-ZONE CRASH
/// ```
///
/// Neither `isClosed` nor `closeCode` can see it: within that one turn nothing
/// observable has changed. So this cannot be guarded here, and a `try`/`catch`
/// around the send does not help — the throw is not on the caller's stack.
///
/// Two ways to be safe. Call [close] and let it close the socket, which sets the
/// flag first and is why every library teardown path is unaffected. Or, if you
/// must close the raw socket yourself, build it inside `runZonedGuarded`: the
/// construction zone is what decides where that throw lands.
///
/// `RpcWebSocketCallerTransport.connect` and the server's accept path build the
/// socket themselves and never hand it out, so a caller using those cannot
/// reach this at all.
class RpcWebSocketChannel implements IRpcChannel, IRpcChannelProtocolClose {
  final WebSocketChannel _ws;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  late final StreamSubscription<void> _sub;
  bool _closed = false;

  RpcWebSocketChannel(this._ws) {
    _sub = _ws.stream.listen(
      (data) {
        if (_incoming.isClosed) return;
        if (data is Uint8List) {
          _incoming.add(data);
        } else if (data is List<int>) {
          _incoming.add(Uint8List.fromList(data));
        } else {
          // Not binary -- in practice a TEXT frame, arriving as a String. This
          // protocol is binary-only, so it is a peer error, and it must not be
          // dropped silently: with no error and no close, nothing anywhere says
          // the peer is misconfigured.
          //
          // ADVISORY, which is what makes "reported rather than fatal" true.
          // The plain RpcException this used to send is what a dead connection
          // sends, and RpcChannelTransport answers that into every per-stream
          // controller -- so one keepalive from a proxy failed every call in
          // flight. The marker stops it at the connection stream, where both
          // endpoints log it.
          _incoming.addError(
            RpcWebSocketNonBinaryFrame(data.runtimeType.toString()),
          );
        }
      },
      onError: (Object e) {
        if (!_incoming.isClosed) _incoming.addError(e);
      },
      onDone: () {
        // Report WHY the peer went away before tearing the pipe down. Without
        // this the close code is lost and every close reaches the caller as the
        // generic UNAVAILABLE core synthesizes for a stream ending with no
        // status -- see [grpcStatusFromWebSocketCloseCode] for why that is
        // worse than imprecise.
        //
        // Emitted as an error on `_incoming` because that is the path a
        // transport-level failure already takes to the endpoint, so pending
        // calls see this rather than the synthesized one.
        //
        // Only when the peer actually SAID something: 1005 "no status received"
        // and 1006 "abnormal closure" mean nothing was said, and 1000/1001 are
        // an orderly goodbye. All four MUST keep ending the stream normally --
        // that is the path reconnect() re-attaches on.
        final code = _ws.closeCode;
        final saidNothing =
            code == null ||
            code == 1000 ||
            code == 1001 ||
            code == 1005 ||
            code == 1006;
        if (!_closed && !saidNothing && !_incoming.isClosed) {
          _incoming.addError(
            RpcStatusException(
              grpcStatusFromWebSocketCloseCode(code),
              'WebSocket closed by peer with code $code'
              '${_ws.closeReason == null || _ws.closeReason!.isEmpty ? '' : ': ${_ws.closeReason}'}',
            ),
          );
        }
        if (!_closed) close();
      },
    );
  }

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) return;
    // NOT batched, though the wire format allows it: a microtask buffer merges
    // nothing, because the sender awaits between frames and the microtask
    // drains before the next one arrives. A timer WOULD merge them, at the
    // price of delaying every lone frame a full event-loop turn -- the wrong
    // trade on a latency-sensitive unary path.
    _ws.sink.add(data);
  }

  /// Close code for a framing violation by the peer.
  ///
  /// 1002 "protocol error" is what this MEANS and cannot be used: an application
  /// may only send 1000 or 3000-4999, and `package:web_socket` throws on
  /// anything else — here, on the teardown path, where the throw is unhandled.
  ///
  /// 4400 echoes HTTP 400. What matters is that
  /// [grpcStatusFromWebSocketCloseCode] maps 3000-4999 to UNKNOWN, which is NOT
  /// retried, so the peer stops resending the frame that got it disconnected.
  /// The reason string is for a human; nothing keys off it.
  static const int _protocolErrorCloseCode = 4400;

  /// A close frame caps its reason at 123 UTF-8 BYTES, and the messages that
  /// reach here carry peer-controlled text — `validateMetadata` quotes the
  /// header name it rejected, and a name is usually invalid for being non-ASCII.
  /// Counting characters lets 84 of them weigh 138 bytes.
  static const int _maxCloseReasonBytes = 120;

  /// Cuts [reason] to [_maxCloseReasonBytes], never mid-code-point.
  static String _trimCloseReason(String reason) {
    final bytes = utf8.encode(reason);
    if (bytes.length <= _maxCloseReasonBytes) return reason;
    var end = _maxCloseReasonBytes;
    // 10xxxxxx is a continuation byte: walk back to the start of its sequence.
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
  }

  @override
  Future<void> closeForProtocolError(String reason) async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _ws.sink.close(_protocolErrorCloseCode, _trimCloseReason(reason));
    } catch (_) {
      // The reason is a courtesy; the CLOSE is the contract. `_closed` is
      // already true above, so a throw here would leave the socket open with no
      // second chance: the peer never learns it violated the policy and never
      // stops resending. Not reachable from the VM test beside this -- the trim
      // keeps it under the cap -- and kept for the platform where close()
      // rejects a reason this one would accept.
      try {
        await _ws.sink.close(_protocolErrorCloseCode);
      } catch (_) {}
    }
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _ws.sink.close();
    } catch (_) {}
    // NOT awaited. `_incoming` is single-subscription, and closing one that was
    // never listened to returns a future that never completes until someone
    // listens -- so awaiting here deadlocks close() outright. Reachable
    // whenever a channel is built but never wrapped (an aborted setup, an error
    // between construction and use), which this class being public makes an
    // ordinary path.
    //
    // Broadcast would also "fix" it and must NOT be used: a broadcast
    // controller DROPS events arriving before the frame channel subscribes,
    // where this one buffers them.
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}
