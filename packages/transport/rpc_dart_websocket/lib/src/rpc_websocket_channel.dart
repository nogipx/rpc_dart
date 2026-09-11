// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

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
          // dropped silently: with no error and no close, a call over this
          // connection hangs to its deadline with nothing in a log and nothing
          // on the wire.
          //
          // Reported rather than fatal, so the connection stays usable for the
          // binary frames around it: closing would turn one stray frame -- an
          // app-level keepalive from a proxy, say -- into a dropped connection.
          _incoming.addError(
            RpcException(
              'RpcWebSocketChannel: expected a binary WebSocket message, got '
              '${data.runtimeType}. This transport is binary-only; a text '
              'frame cannot carry an RPC frame and was discarded.',
            ),
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

  @override
  Future<void> closeForProtocolError(String reason) async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      // WebSocket caps the close reason at 123 BYTES and dart:io throws past
      // that, turning a tidy protocol close into an exception on the teardown
      // path. Frame-exception messages carry byte counts and limits, so they
      // run past it easily.
      final trimmed = reason.length > 100
          ? '${reason.substring(0, 97)}...'
          : reason;
      await _ws.sink.close(_protocolErrorCloseCode, trimmed);
    } catch (_) {}
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
