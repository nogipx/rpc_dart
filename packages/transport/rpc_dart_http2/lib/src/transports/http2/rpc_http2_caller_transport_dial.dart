// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

part of 'rpc_http2_caller_transport.dart';

/// Ceiling on a proxy's CONNECT response headers.
///
/// `headerBuf` accumulates until CRLFCRLF appears, so an unbounded read makes
/// a proxy that streams headers forever an OOM on the CLIENT. A real CONNECT
/// response is a status line and a handful of headers; 64 KiB is already
/// absurdly generous.
///
/// A proxy is a machine on the path and often not the operator's, so trusting
/// it without bound is the wrong default.
const int _maxProxyHeaderBytes = 64 * 1024;

/// Builds the http2 connection with the peer's header blocks bounded.
///
/// A CLIENT is exposed to the CONTINUATION flood exactly as the server was
/// (fixed for RpcHttp2Server in the previous round): package:http2
/// concatenates a HEADERS frame and its CONTINUATION frames into one
/// unbounded buffer, rebuilding it on every frame, and does so BEFORE any
/// stream-state handling -- so the stream need not even exist and nothing
/// above the transport can see it.
///
/// A hostile server answering with HEADERS that lack END_HEADERS and then
/// CONTINUATION frames forever costs the CLIENT more RSS than the same flood
/// costs the server, with the transport still reporting open throughout.
///
/// "You dialed the server" is not a defence: a client gets pointed at a
/// compromised endpoint, and a proxy is a machine on the path that is often
/// not the operator's — the same reasoning that bounds the CONNECT response
/// in [_maxProxyHeaderBytes].
///
/// [skipConnectionPreface] is false here and must stay false: the 24-octet
/// preface travels client-to-server only, so a client that skipped 24 bytes
/// would misparse the server's first frames.
///
/// [settingsTimeout] bounds the wait for the peer's first SETTINGS. A peer
/// that accepts TCP and never speaks h2 otherwise reads as a live connection
/// forever, and every call on it waits on its own deadline or never ends.
/// On expiry the socket is destroyed, which ends the connection the usual
/// way. Null leaves it unbounded.
http2.ClientTransportConnection _guardedConnection({
  required Stream<List<int>> incoming,
  required StreamSink<List<int>> outgoing,
  required void Function() destroy,
  required RpcSecurityPolicy policy,
  required Duration? settingsTimeout,
  LogScope? logger,
  _DrainSignal? drainSignal,
}) {
  final number = drainSignal == null ? 0 : ++drainSignal.built;
  Timer? settingsWatch;
  if (settingsTimeout != null) {
    settingsWatch = Timer(settingsTimeout, () {
      logger?.warning(
        'HTTP/2 peer sent no SETTINGS within $settingsTimeout; '
        'closing connection',
      );
      destroy();
    });
  }
  final guarded = guardHttp2HeaderBlock(
    incoming,
    maxHeaderBlockBytes: policy.maxMetadataBytes,
    skipConnectionPreface: false,
    onEnd: () {
      // A pending timer would hold the process open after a close.
      settingsWatch?.cancel();
      drainSignal?.onSocketEnded?.call(number);
    },
    onGoaway: () {
      logger?.internal('HTTP/2 peer sent GOAWAY: this connection is draining');
      drainSignal?.goawayReceived = true;
    },
    onViolation: (observedBytes) {
      logger?.warning(
        'HTTP/2 header-block cap exceeded by the peer: $observedBytes bytes '
        '(max: ${policy.maxMetadataBytes}); closing connection',
      );
      destroy();
    },
  );
  final connection = http2.ClientTransportConnection.viaStreams(
    guarded,
    outgoing,
  );
  if (settingsWatch != null) {
    unawaited(
      connection.onInitialPeerSettingsReceived.then(
        (_) => settingsWatch?.cancel(),
        onError: (Object _) => settingsWatch?.cancel(),
      ),
    );
  }
  return connection;
}

/// Establishes an HTTP/2 connection through an HTTP CONNECT proxy.
///
/// The handshake uses a SINGLE, persistent socket subscription — kept alive
/// for a plaintext tunnel, cancelled before the TLS upgrade. Re-subscribing
/// to a single-subscription Socket stream throws StateError the moment http2
/// calls `socket.listen()` again.
Future<http2.ClientTransportConnection> _connectH2ViaProxy({
  required Uri proxyUri,
  required String targetHost,
  required int targetPort,
  required bool secure,
  required RpcSecurityPolicy policy,
  Duration handshakeTimeout = RpcHttp2CallerTransport._proxyHandshakeTimeout,
  Duration? connectTimeout,
  LogScope? logger,
  _DrainSignal? drainSignal,
}) async {
  final proxyHost = proxyUri.host;
  final proxyPort = proxyUri.hasPort ? proxyUri.port : 3128;

  // `connectTimeout` bounds the two phases here that are not the CONNECT
  // exchange (that one has `handshakeTimeout`): reaching the proxy, and the
  // TLS handshake through the tunnel. See the direct paths for why
  // `timeout:` rather than an outer `.timeout()` on the socket connect.
  // A RawSocket throughout, not a Socket: it is the only kind that stays
  // closable through the TLS handshake. Once SecureSocket.secure owns a
  // Socket, destroying the original no longer closes it, so a handshake
  // that timed out left its socket to the proxy open. See RawSocketPipe.
  final raw = await RawSocket.connect(
    proxyHost,
    proxyPort,
    timeout: connectTimeout,
  );
  try {
    raw.setOption(SocketOption.tcpNoDelay, true);
  } catch (error) {
    logger?.warning('Could not disable Nagle on proxy socket: $error');
  }

  // Build CONNECT request. The target in authority-form, so an IPv6 literal
  // is bracketed.
  final target =
      '${RpcHttp2CallerTransport._authorityHost(targetHost)}:$targetPort';
  final reqBuf = StringBuffer()
    ..write('CONNECT $target HTTP/1.1\r\n')
    ..write('Host: $target\r\n');
  if (proxyUri.userInfo.isNotEmpty) {
    // Basic auth takes the credentials themselves; a URI spells an `@` or a
    // `:` inside them percent-encoded. Decoded per part, so an encoded `:` in
    // the user name cannot move the split.
    final info = proxyUri.userInfo;
    final split = info.indexOf(':');
    final credentials = split < 0
        ? Uri.decodeComponent(info)
        : '${Uri.decodeComponent(info.substring(0, split))}:'
              '${Uri.decodeComponent(info.substring(split + 1))}';
    reqBuf.write(
      'Proxy-Authorization: Basic ${base64Encode(utf8.encode(credentials))}\r\n',
    );
  }
  reqBuf.write('\r\n');
  final request = utf8.encode(reqBuf.toString());

  // ONE subscription for the socket's whole life: the CONNECT exchange reads
  // through it, then it is handed to RawSecureSocket.secure or to the pipe.
  final handshake = Completer<void>();
  final headerBuf = <int>[];
  var leftover = Uint8List(0);
  var written = 0;
  late final StreamSubscription<RawSocketEvent> sub;
  void fail(Object error) {
    if (!handshake.isCompleted) handshake.completeError(error);
  }

  sub = raw.listen(
    (event) {
      if (handshake.isCompleted) return;
      switch (event) {
        case RawSocketEvent.write:
          written += raw.write(request, written);
          if (written >= request.length) raw.writeEventsEnabled = false;
        case RawSocketEvent.read:
          final chunk = raw.read();
          if (chunk == null) return;
          headerBuf.addAll(chunk);
          final endIdx = _indexOfEndOfHeaders(headerBuf);
          if (endIdx == -1) {
            if (headerBuf.length > _maxProxyHeaderBytes) {
              fail(
                SocketException(
                  'HTTP proxy sent more than $_maxProxyHeaderBytes bytes of '
                  'CONNECT response headers without terminating them',
                ),
              );
            }
            return;
          }
          final statusLine = String.fromCharCodes(
            headerBuf.sublist(0, endIdx),
          ).split('\r\n').first;
          if (!RegExp(r'HTTP/\S+ 2\d\d').hasMatch(statusLine)) {
            fail(
              SocketException(
                'HTTP proxy CONNECT rejected: ${statusLine.trim()}',
              ),
            );
            return;
          }
          // Bytes after \r\n\r\n (unusual but possible): kept for the
          // tunnel.
          leftover = Uint8List.fromList(headerBuf.sublist(endIdx + 4));
          // No more reads until the next stage takes the subscription
          // over. Not a pause: RawSecureSocket.secure refuses a paused
          // subscription.
          raw.readEventsEnabled = false;
          handshake.complete();
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          fail(SocketException('Proxy closed during CONNECT'));
      }
    },
    onError: fail,
    onDone: () => fail(SocketException('Proxy closed during CONNECT')),
  );
  raw.writeEventsEnabled = true;

  // Bounded, and the socket is released on the way out: abandoning the await
  // without closing the socket would leak it -- Future.timeout abandons the
  // await, not the work.
  try {
    await handshake.future.timeout(handshakeTimeout);
  } catch (error) {
    await sub.cancel();
    await raw.close();
    if (error is TimeoutException) {
      throw SocketException(
        'HTTP proxy did not answer CONNECT within $handshakeTimeout',
      );
    }
    rethrow;
  }

  if (secure) {
    if (leftover.isNotEmpty) {
      await sub.cancel();
      await raw.close();
      throw SocketException(
        'HTTP proxy sent tunnel bytes before the TLS handshake began',
      );
    }
    // The bound closes the RawSocket, which -- unlike a Socket handed to
    // SecureSocket.secure -- really closes the handshake's socket.
    final handshake = RawSecureSocket.secure(
      raw,
      subscription: sub,
      host: targetHost,
      supportedProtocols: ['h2'],
    );
    final RawSecureSocket secureSocket;
    try {
      secureSocket = connectTimeout == null
          ? await handshake
          : await handshake.timeout(connectTimeout);
    } on TimeoutException {
      await raw.close();
      throw SocketException(
        'TLS handshake through the proxy did not finish within '
        '$connectTimeout',
      );
    } catch (_) {
      await raw.close();
      rethrow;
    }
    final chosen = secureSocket.selectedProtocol;
    if (chosen != 'h2') {
      await secureSocket.close();
      throw SocketException(
        'TLS peer $targetHost:$targetPort did not negotiate HTTP/2 '
        '(ALPN: ${chosen ?? 'none'})',
      );
    }
    final pipe = RawSocketPipe(secureSocket);
    return _guardedConnection(
      incoming: pipe.incoming,
      outgoing: pipe,
      destroy: pipe.destroy,
      policy: policy,
      settingsTimeout: connectTimeout,
      logger: logger,
      drainSignal: drainSignal,
    );
  }
  // The guard sits on the tunnel's stream, so it bounds what the TUNNELED
  // peer sends as well as anything the proxy injects.
  final pipe = RawSocketPipe(raw, subscription: sub);
  final Stream<List<int>> incoming = leftover.isEmpty
      ? pipe.incoming
      : _prepend(leftover, pipe.incoming);
  return _guardedConnection(
    incoming: incoming,
    outgoing: pipe,
    destroy: pipe.destroy,
    policy: policy,
    settingsTimeout: connectTimeout,
    logger: logger,
    drainSignal: drainSignal,
  );
}

/// [first], then everything [rest] delivers.
Stream<List<int>> _prepend(List<int> first, Stream<List<int>> rest) async* {
  yield first;
  yield* rest;
}

/// Refuses a TLS peer that did not choose `h2` in ALPN.
///
/// Offering `h2` is a request, not a guarantee: a server that speaks only
/// HTTP/1.1 completes the handshake without choosing it, and an h2 preface
/// sent to it fails later with an error that does not say why. The socket is
/// destroyed and the reason named here instead.
void _requireH2(SecureSocket socket, String peer) {
  final chosen = socket.selectedProtocol;
  if (chosen == 'h2') return;
  socket.destroy();
  throw SocketException(
    'TLS peer $peer did not negotiate HTTP/2 '
    '(ALPN: ${chosen ?? 'none'})',
  );
}

int _indexOfEndOfHeaders(List<int> bytes) {
  for (var i = 0; i <= bytes.length - 4; i++) {
    if (bytes[i] == 0x0D &&
        bytes[i + 1] == 0x0A &&
        bytes[i + 2] == 0x0D &&
        bytes[i + 3] == 0x0A) {
      return i;
    }
  }
  return -1;
}
