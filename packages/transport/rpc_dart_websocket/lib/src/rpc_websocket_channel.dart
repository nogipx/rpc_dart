// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// [IRpcChannel] implementation wrapping a [WebSocketChannel].
///
/// Converts the WebSocket message stream into a raw byte pipe.
/// Combine with [RpcChannelTransport.fromChannel] to get a full
/// [IRpcTransport] with multiplexing, security, and health checks.
///
/// ```dart
/// final wsChannel = WebSocketChannel.connect(uri);
/// final transport = RpcChannelTransport.fromChannel(
///   channel: RpcWebSocketChannel(wsChannel),
///   isClient: true,
/// );
/// ```
/// gRPC status for the WebSocket close code the peer hung up with.
///
/// A close code is the only thing a WebSocket peer can say about WHY it went
/// away, and it was previously discarded: every close produced the same
/// `UNAVAILABLE: Stream closed without receiving response`, whatever the
/// server meant. Measured against a real dart:io server closing mid-call, all
/// of 1001, 1008, 1009 and 1011 were indistinguishable.
///
/// UNAVAILABLE is RETRYABLE ([RpcRetryInterceptor] retries it), so flattening
/// everything to it meant retrying failures that cannot succeed: a server that
/// hung up for a policy violation, or on its own internal error, was hammered
/// maxAttempts times. The split below is mostly about that.
///
/// - 1000 normal, 1001 going away, 1005/1006 no-status/abnormal, and
///   1012/1013/1014 restart / try-again / bad-gateway are CONNECTION-level and
///   transient, so `unavailable` and retryable. 1001 and 1012/1013 are the
///   WebSocket analogue of HTTP/2 GOAWAY — a shutdown or a draining load
///   balancer.
/// - 1008 policy violation is `permissionDenied`: deterministic, and retrying
///   it is exactly the loop this fixes.
/// - 1009 message too big is `resourceExhausted`, the gRPC code for a message
///   over the limit. Note this one IS retried by the default interceptor, and
///   re-sending the same oversized message will fail identically — bounded by
///   maxAttempts, but wasteful. Set `retryOn` if that matters; the semantically
///   correct code is preferred here over hiding it as INTERNAL.
/// - 1002/1003/1007/1010/1011 are protocol or server faults: `internal`, which
///   is NOT retried.
/// - 3000-4999 are library/application codes with no fixed meaning, so
///   `unknown` — the peer said something gRPC has no word for, which is what
///   `unknown` means. Same rule as `grpcStatusFromHttpStatus`.
int grpcStatusFromWebSocketCloseCode(int? closeCode) => switch (closeCode) {
  null => RpcStatus.unavailable,
  1000 || 1001 || 1005 || 1006 => RpcStatus.unavailable,
  1012 || 1013 || 1014 => RpcStatus.unavailable,
  1008 => RpcStatus.permissionDenied,
  1009 => RpcStatus.resourceExhausted,
  1002 || 1003 || 1007 || 1010 || 1011 => RpcStatus.internal,
  _ => RpcStatus.unknown,
};

class RpcWebSocketChannel implements IRpcChannel {
  final WebSocketChannel _ws;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  late final StreamSubscription _sub;
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
          // Anything that is not binary -- in practice a WebSocket TEXT frame,
          // which arrives as a String. This protocol is binary-only, so a text
          // frame is a peer error.
          //
          // It used to fall through both branches and vanish: measured against
          // a real dart:io WebSocket server, sending a text frame left
          // `connectionClosed=false error=none` and the peer got no signal at
          // all, so a call made over that connection simply hung until its
          // deadline. Silent loss is the worst of the options -- nothing to
          // see in a log, nothing on the wire.
          //
          // Reported rather than fatal. The error travels
          // RpcFrameMultiplexedChannel -> RpcChannelTransport -> the endpoint's
          // incoming stream, where it is logged, and the connection stays
          // usable for the binary frames around it. Closing instead would turn
          // one stray frame -- an app-level keepalive from a proxy, say -- into
          // a dropped connection, which is a bigger change than the defect
          // being fixed here.
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
        // Report WHY the peer went away before tearing the pipe down.
        //
        // The close code is the only explanation a WebSocket peer can give,
        // and it used to be dropped on the floor: every close, for every
        // reason, reached the caller as the generic "Stream closed without
        // receiving response" UNAVAILABLE that core synthesizes when a stream
        // ends with no status. Measured against a real dart:io server closing
        // mid-call, these four were byte-for-byte identical:
        //
        //   1001 going away      -> UNAVAILABLE Stream closed without ...
        //   1008 policy violation-> UNAVAILABLE Stream closed without ...
        //   1009 message too big -> UNAVAILABLE Stream closed without ...
        //   1011 internal error  -> UNAVAILABLE Stream closed without ...
        //
        // UNAVAILABLE is retryable, so the flattening did not merely lose
        // information -- it made the client RETRY a policy rejection and a
        // server-side internal error, neither of which can ever succeed.
        //
        // Emitted as an error on `_incoming` rather than plumbed through
        // close(): that is the path a transport-level failure already takes to
        // the endpoint, so pending calls see this instead of the synthesized
        // one. Only for codes that mean something went wrong; a clean 1000/1001
        // shutdown still ends the stream normally so an idle connection closing
        // is not reported as a call failure.
        // Only when the peer actually SAID something. 1005 "no status
        // received" and 1006 "abnormal closure" are the codes for "nothing was
        // said" -- a socket that simply dropped -- and 1000/1001 are an
        // orderly goodbye. All four must keep ending the stream normally:
        // that is the path reconnect() re-attaches on, and the existing
        // reconnect tests pin it. Raising an error for 1005 broke three of
        // them, which is what narrowed this list.
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
    _ws.sink.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    try {
      await _ws.sink.close();
    } catch (_) {}
    // NOT awaited. `_incoming` is single-subscription, and closing one that
    // was never listened to returns a future that does not complete until
    // someone listens -- so `await` here deadlocked close() outright.
    //
    // The normal path is safe because RpcFrameMultiplexedChannel subscribes in
    // its constructor. The path that is not is closing a channel that was
    // built but never wrapped: an aborted setup, or an error between
    // construction and use -- exactly when cleanup has to work. This class is
    // public and documented for direct construction, so that is reachable.
    //
    // Measured, with a listener as the control:
    //   no listener : close() still pending after 3s, forever
    //   listener    : close() returns
    //
    // Same fault as the CONNECT-proxy deadlock in dcc14f8c. Broadcast would
    // also "fix" it and must NOT be used: a broadcast controller DROPS events
    // that arrive before the frame channel subscribes, where this one buffers
    // them.
    if (!_incoming.isClosed) unawaited(_incoming.close());
  }
}
