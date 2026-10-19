// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'rpc_websocket_channel.dart';
import 'ws_open_stub.dart' if (dart.library.io) 'ws_open_io.dart';

/// Client-side WebSocket transport.
///
/// An [RpcChannelTransport] over the 3-layer architecture:
/// [RpcWebSocketChannel] -> [RpcFrameMultiplexedChannel] -> [RpcChannelTransport],
/// plus the library's own keepalive where the platform has none.
///
/// One transport is one socket. When the socket is lost the transport closes;
/// for reconnects, give `RpcClientConnection` a factory that calls [connect].
class RpcWebSocketCallerTransport extends RpcChannelTransport {
  /// Drives [_startAppLevelHeartbeat]; null means no heartbeat.
  ///
  /// Null exactly when something ELSE is already pinging this socket — which is
  /// knowable only where this transport opened it. Via
  /// [RpcWebSocketCallerTransport.connect] that is dart:io on the VM and nothing
  /// on the web; for a channel handed to the constructor it is nobody, so the
  /// interval stands and this library's own ping runs.
  final Duration? _heartbeatInterval;

  Timer? _heartbeat;
  bool _heartbeatProbeInFlight = false;

  /// Wraps an already-built [channel].
  ///
  /// The channel may still be connecting: its `ready` becomes this transport's
  /// [ready], which `RpcClientConnection` awaits before it reports Online.
  ///
  /// [pingInterval] runs THIS library's keepalive at that cadence, on every
  /// platform — not the socket's own. A [WebSocketChannel] does not expose the
  /// socket underneath (`IOWebSocketChannel` keeps it private), so this
  /// constructor can neither apply a native ping to it nor ask whether one is
  /// already running. Running its own is the only answer available, and the
  /// alternative was silence: `platformHonoursPingInterval` describes what
  /// `openWebSocket` does, and nothing here called `openWebSocket`.
  ///
  /// If you built the channel with a native ping — `IOWebSocketChannel.connect(
  /// url, pingInterval: ...)` — leave this null, or pass
  /// `platformHandlesPing: true`, and the socket's own keepalive is the only one.
  ///
  /// [RpcWebSocketCallerTransport.connect] opens the socket itself, so it knows
  /// the answer and passes it: native on the VM, this library's ping on the web.
  RpcWebSocketCallerTransport(
    WebSocketChannel channel, {
    super.policy,
    Duration? pingInterval,
    bool? platformHandlesPing,
    super.logger,
  }) : // Defaults to "nobody is pinging this socket", because for a channel
       // handed in that is all this constructor can know. `connect()` passes
       // `platformHonoursPingInterval` explicitly, which is the only place that
       // constant's premise holds -- it describes `openWebSocket`, and a caller
       // who built the channel never went through it.
       _heartbeatInterval = (platformHandlesPing ?? false)
           ? null
           : pingInterval,
       super.fromChannel(
         channel: RpcWebSocketChannel(channel),
         isClient: true,
         ready: channel.ready,
       ) {
    _startAppLevelHeartbeat();
  }

  /// Probes the peer with the library's own ping where the platform will not.
  ///
  /// A browser owns ping/pong and exposes neither the interval nor the outcome,
  /// so a missing pong never reaches the page and a web client on a half-open
  /// path has NO liveness signal — measured at 626 ms to notice on the VM
  /// against never, at the same interval.
  ///
  /// Uses `RpcEndpointPingExchange`, not a new frame type: the protocol already
  /// has a probe, and any rpc_dart responder answers it. The failure ANSWER
  /// matches what dart:io does with a missing pong — close the transport — so
  /// a supervisor polling `health()` or `RpcClientConnection` sees the same
  /// thing on both platforms.
  void _startAppLevelHeartbeat() {
    final interval = _heartbeatInterval;
    if (interval == null) return;
    _heartbeat = Timer.periodic(interval, (timer) async {
      // One probe at a time: a slow-but-alive peer must not accumulate pings,
      // and a stalled one would otherwise start a new one every interval.
      if (_heartbeatProbeInFlight || isClosed) return;
      _heartbeatProbeInFlight = true;
      try {
        final streamId = createStream();
        try {
          await RpcEndpointPingExchange(
            transport: this,
            streamId: streamId,
            sentAt: DateTime.timestamp(),
          ).execute(
            metadata: RpcMetadata.forClientRequest(
              RpcEndpointPingProtocol.serviceName,
              RpcEndpointPingProtocol.methodName,
            ),
            // One interval, exactly as dart:io: a pong that has not arrived by
            // the next probe is what "dead" means here.
            timeout: interval,
          );
        } finally {
          releaseStreamId(streamId);
        }
      } on TimeoutException {
        // SILENCE, and only silence, is death. Nothing came back within one
        // interval, which is the half-open path this exists for, and the answer
        // matches dart:io's on a missing pong: close.
        timer.cancel();
        _heartbeat = null;
        unawaited(close().catchError((Object _) {}));
      } catch (_) {
        // Every other failure means the probe never went out, or the peer
        // ANSWERED. Neither is evidence of a dead path, and closing on one
        // takes a healthy connection down: at `maxActiveStreams` `createStream`
        // throws resourceExhausted, and a catch-all here killed the very calls
        // that filled the ceiling. Skipped, not swallowed -- the next interval
        // probes again. Caught at all because this is a detached timer
        // callback, where an unhandled async error reaches the root zone.
      } finally {
        _heartbeatProbeInFlight = false;
      }
    });
  }

  /// Connects to the given WebSocket [uri].
  ///
  /// Awaits [WebSocketChannel.ready] before returning, so the returned Future
  /// rejects if the URL is invalid or the server is unreachable. This ensures
  /// connection errors are reported through the transport factory rather than
  /// leaking as unhandled stream errors.
  ///
  /// [pingInterval] enables WebSocket keepalive, the ONLY way to detect a
  /// half-open connection: a NAT box, load balancer or mobile network that
  /// silently stops forwarding, with no FIN and no RST, so both peers still
  /// believe the socket is fine. Without it a call on a dead path hangs
  /// indefinitely while `health()` still reports healthy. On the VM, dart:io
  /// pings every interval and closes if no pong returns within one.
  ///
  /// Null (OFF) by default, because the right interval is a deployment
  /// question: too short wastes battery and wakes mobile radios, too long
  /// leaves calls hanging. Take the shortest idle timeout on the path — load
  /// balancers commonly use 60s — and halve it.
  ///
  /// On the WEB the browser drops it: ping/pong lives inside the browser's own
  /// WebSocket implementation, which exposes neither the interval nor the
  /// outcome, so a missing pong never surfaces to the page. The transport
  /// therefore runs the library's own ping at the same cadence there and
  /// closes when one goes unanswered — the same answer dart:io gives, reached a
  /// different way. Measured at 626 ms to notice against never, at a 300 ms
  /// interval.
  ///
  /// ```
  ///   transport            half-open detected by
  ///   websocket (VM)       WebSocket.pingInterval, native
  ///   websocket (web)      this transport's own RpcEndpointPingExchange loop
  ///   http2                startHttp2Keepalive, this library's own loop
  ///   isolate              the port closing
  /// ```
  ///
  /// **Only SILENCE counts as death.** A probe that could not be sent, or one
  /// the peer answered with an error, leaves the connection alone and retries
  /// next interval: at `maxActiveStreams` `createStream` throws, and treating
  /// that as a dead peer closed a healthy connection along with every call
  /// holding those ids.
  ///
  /// [headers] go on the upgrade REQUEST — the only place a websocket client
  /// can authenticate, since there is no second round trip to attach a token
  /// to. **VM only**: the browser WebSocket API takes no request headers, so a
  /// web client uses a cookie, a `Sec-WebSocket-Protocol` value or a query
  /// parameter. They are ignored there rather than rejected, so one piece of
  /// cross-platform code can pass a token without branching on the platform.
  /// For a token that expires, read it in the `RpcClientConnection` factory,
  /// which calls this once per attempt.
  ///
  /// [connectTimeout] bounds the whole open, on both platforms. A peer that
  /// accepts TCP and never completes the upgrade is bounded by nothing else:
  /// the OS does not time out a missing HTTP response, and an
  /// `RpcClientConnection` awaiting this stays in Connecting. 30 s by default,
  /// as the http2 caller; pass null to wait without a bound.
  ///
  /// A failed open throws an [RpcStatusException], as the http caller reports
  /// the same failures. A refused upgrade carries its HTTP status mapped by
  /// [grpcStatusFromHttpStatus], so a `shouldReconnect` can stop on
  /// UNAUTHENTICATED (401) or PERMISSION_DENIED (403). On the web, and with
  /// [enableCompression] on, the platform does not expose that status and the
  /// refusal is UNAVAILABLE. A refused connection, a connection closed during
  /// the upgrade and [connectTimeout] are UNAVAILABLE. An [Error] (a malformed
  /// [uri]) passes through unchanged.
  ///
  /// [enableCompression] is false so the client does not OFFER
  /// permessage-deflate, which a hostile or compromised server could otherwise
  /// negotiate and flood it through: dart:io inflates an incoming message with
  /// no output bound before rpc_dart sees it, turning a fraction of a MiB on
  /// the wire into hundreds of MiB of client RSS. Mirrors the server default in
  /// rpcWebSocketConnections; enable it only against servers you control.
  static Future<RpcWebSocketCallerTransport> connect(
    Uri uri, {
    Iterable<String>? protocols,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    Duration? pingInterval,
    bool enableCompression = false,
    Map<String, Object>? headers,
    Duration? connectTimeout = const Duration(seconds: 30),
    LogScope? logger,
  }) async {
    final WebSocketChannel channel;
    try {
      channel = await openWebSocket(
        uri,
        protocols: protocols,
        pingInterval: pingInterval,
        enableCompression: enableCompression,
        headers: headers,
        connectTimeout: connectTimeout,
        maxMessageBytes: _guardCeiling(policy),
      );
    } catch (e, st) {
      Error.throwWithStackTrace(_connectFailure(e, uri), st);
    }
    return RpcWebSocketCallerTransport(
      channel,
      policy: policy,
      // Passed on so the parameter means the same thing on both platforms: the
      // VM lets dart:io handle it, the web runs the library's own ping at the
      // same cadence.
      pingInterval: pingInterval,
      // Stated HERE, because this is the only path where the constant applies:
      // `openWebSocket` above is what it describes. The constructor cannot
      // assume it -- see its doc.
      platformHandlesPing: platformHonoursPingInterval,
      logger: logger,
    );
  }

  /// The frame guard's ceiling: the multiplexer's reassembly cap, never below
  /// the default policy's, as on the server.
  ///
  /// A whole message past a stricter policy must still reach the multiplexer,
  /// which fails that one call; the guard can only drop the connection.
  static int _guardCeiling(RpcSecurityPolicy policy) {
    final own = policy.maxChannelFrameBytes;
    final floor = const RpcSecurityPolicy().maxChannelFrameBytes;
    return own > floor ? own : floor;
  }

  /// A failed open as a gRPC status. See [connect].
  ///
  /// Any [Exception] is the I/O underneath -- dart:io's, or the browser's
  /// through `WebSocketChannelException` -- and UNAVAILABLE: no call was made,
  /// so a fresh attempt may succeed. dart:io cannot be named here because this
  /// file compiles for the web. An [Error] is a bug and passes through.
  ///
  /// The message quotes the error with [uri]'s userinfo and query blanked.
  /// dart:io writes the whole uri into its errors, and the query is where a
  /// web client puts its token, so the text would carry it into every log
  /// that records a failed attempt (`RpcClientConnection` warns on each).
  static Object _connectFailure(Object error, Uri uri) {
    if (error is RpcException) return error;
    if (error is Exception) {
      var text = '$error';
      for (final secret in [uri.userInfo, uri.query]) {
        if (secret.isNotEmpty) text = text.replaceAll(secret, '<redacted>');
      }
      return RpcStatusException(
        RpcStatus.unavailable,
        'WebSocket connect failed: $text',
      );
    }
    return error;
  }

  @override
  Future<void> close() {
    // Before the close: a timer left running fires against a torn-down
    // transport and reports a dead peer for a socket the caller closed itself.
    _heartbeat?.cancel();
    _heartbeat = null;
    return super.close();
  }
}
