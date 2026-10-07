// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// Upgrades [request] to a server-side [WebSocket] whose inbound messages may
/// not exceed [maxMessageBytes].
///
/// dart:io assembles a whole message before delivering it and has no ceiling
/// of its own, so a peer that keeps sending fragments without a final one is
/// buffered for as long as it writes. The ceiling is applied to the raw socket
/// from each frame's header, before dart:io sees the payload.
///
/// No `permessage-deflate`: the caller takes the dart:io path when compression
/// is on.
Future<WebSocket> upgradeBounded(
  HttpRequest request, {
  required int maxMessageBytes,
  dynamic Function(List<String> protocols)? protocolSelector,
}) async {
  final response = request.response;
  String? protocol;
  final offered = request.headers['Sec-WebSocket-Protocol'];
  if (offered != null && protocolSelector != null) {
    final tokens = offered
        .join(',')
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    try {
      final selected = await protocolSelector(tokens);
      if (selected is! String || !tokens.contains(selected)) {
        throw const WebSocketException(
          'Selected protocol is not in the list of available protocols',
        );
      }
      protocol = selected;
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
      await response.close().catchError((Object _) {});
      rethrow;
    }
  }

  // `headers[...]`, not `value()`, which throws on a repeated header.
  final keys = request.headers['Sec-WebSocket-Key'];
  if (keys == null || keys.length != 1) {
    response.statusCode = HttpStatus.badRequest;
    await response.close().catchError((Object _) {});
    throw const WebSocketException('Invalid WebSocket upgrade request');
  }
  final accept = base64Encode(
    sha1.convert(utf8.encode('${keys.single.trim()}$_webSocketGuid')).bytes,
  );
  response
    ..statusCode = HttpStatus.switchingProtocols
    ..headers.add(HttpHeaders.connectionHeader, 'Upgrade')
    ..headers.add(HttpHeaders.upgradeHeader, 'websocket')
    ..headers.add('Sec-WebSocket-Accept', accept);
  if (protocol != null) {
    response.headers.add('Sec-WebSocket-Protocol', protocol);
  }
  response.headers.contentLength = 0;
  final socket = await response.detachSocket();
  return WebSocket.fromUpgradedSocket(
    _BoundedSocket(socket, maxMessageBytes),
    protocol: protocol,
    serverSide: true,
    compression: CompressionOptions.compressionOff,
  );
}

/// A [Socket] whose inbound bytes pass through a [WebSocketFrameGuard].
///
/// Past the ceiling the socket is destroyed: dart:io writes to it through
/// `addStream`, so a close frame of our own cannot be interleaved safely.
final class _BoundedSocket extends StreamView<Uint8List> implements Socket {
  _BoundedSocket(this._socket, int maxMessageBytes)
    : super(_guarded(_socket, maxMessageBytes));

  final Socket _socket;

  static Stream<Uint8List> _guarded(Socket socket, int maxMessageBytes) {
    final guard = WebSocketFrameGuard(maxMessageBytes);
    StreamSubscription<Uint8List>? source;
    late final StreamController<Uint8List> out;
    out = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        source = socket.listen(
          (data) {
            if (guard.admit(data)) {
              out.add(data);
              return;
            }
            // Bytes read together with the upgrade request are replayed by
            // dart:http and keep arriving after destroy(); only cancelling
            // the subscription stops them.
            unawaited(source?.cancel());
            socket.destroy();
            unawaited(out.close());
          },
          onError: out.addError,
          onDone: out.close,
        );
      },
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () => source?.cancel(),
    );
    return out.stream;
  }

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get port => _socket.port;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);

  @override
  void destroy() => _socket.destroy();

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> flush() => _socket.flush();

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
}

/// Reads WebSocket frame headers off a byte stream and refuses a message whose
/// declared length crosses [maxMessageBytes], or a peer pinging faster than
/// [maxPingsPerSecond].
///
/// Counts what a header DECLARES, so the refusal comes before the payload is
/// read: a fragmented message is summed across its fragments, and a control
/// frame (which may arrive between them) counts toward nothing but may not
/// exceed 125 bytes, the protocol's own limit.
///
/// Pings are rate-limited because dart:io answers each with a pong queued on
/// an unbounded write buffer: a client that sends pings and never reads makes
/// the server hold a pong for every ping, at the client's upload rate. A
/// burst of [maxPingBurst] is allowed, refilled at [maxPingsPerSecond]; a
/// keepalive pings once per interval and browsers do not ping at all.
final class WebSocketFrameGuard {
  /// Creates a guard with the given per-message ceiling. [now] reads a
  /// monotonic clock in microseconds, for tests.
  WebSocketFrameGuard(this.maxMessageBytes, {int Function()? now})
    : _now = now ?? _monotonic,
      _pingTokens = maxPingBurst.toDouble();

  /// Ceiling on one message's payload, summed over its fragments.
  final int maxMessageBytes;

  /// Pings admitted at once before the rate applies.
  static const int maxPingBurst = 256;

  /// Sustained pings admitted per second.
  static const int maxPingsPerSecond = 16;

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonic() => _clock.elapsedMicroseconds;

  final int Function() _now;
  double _pingTokens;
  int? _pingRefilledAt;

  /// Spends one ping token; false when the bucket is empty.
  bool _admitPing() {
    final now = _now();
    final last = _pingRefilledAt ?? now;
    _pingRefilledAt = now;
    _pingTokens += (now - last) * maxPingsPerSecond / 1000000;
    if (_pingTokens > maxPingBurst) _pingTokens = maxPingBurst.toDouble();
    if (_pingTokens < 1) return false;
    _pingTokens -= 1;
    return true;
  }

  final Uint8List _header = Uint8List(14);
  int _headerLen = 0;
  int _remaining = 0;
  bool _inPayload = false;
  bool _finalData = false;
  int _messageBytes = 0;

  /// Feeds [data]; false once a frame is past a ceiling, after which nothing
  /// more should be read.
  bool admit(Uint8List data) {
    var i = 0;
    while (i < data.length) {
      if (_inPayload) {
        final available = data.length - i;
        final skip = _remaining < available ? _remaining : available;
        _remaining -= skip;
        i += skip;
        if (_remaining == 0) _endFrame();
        continue;
      }
      _header[_headerLen++] = data[i++];
      final needed = _headerLength();
      if (needed == null || _headerLen < needed) continue;
      if (!_startFrame(needed)) return false;
    }
    return true;
  }

  /// Total header length once enough of it is known, else null.
  int? _headerLength() {
    if (_headerLen < 2) return null;
    final len7 = _header[1] & 0x7f;
    final extended = len7 == 126 ? 2 : (len7 == 127 ? 8 : 0);
    final mask = (_header[1] & 0x80) != 0 ? 4 : 0;
    return 2 + extended + mask;
  }

  bool _startFrame(int headerLength) {
    final view = ByteData.sublistView(_header);
    final len7 = _header[1] & 0x7f;
    final int length = len7 == 126
        ? view.getUint16(2)
        : len7 == 127
        ? view.getInt64(2)
        : len7;
    final opcode = _header[0] & 0x0f;
    final fin = (_header[0] & 0x80) != 0;
    _headerLen = 0;
    if (length < 0) return false;
    if (opcode >= 8) {
      if (length > 125) return false;
      if (opcode == 0x9 && !_admitPing()) return false;
      _finalData = false;
    } else {
      _messageBytes += length;
      if (_messageBytes > maxMessageBytes) return false;
      _finalData = fin;
    }
    _remaining = length;
    _inPayload = length > 0;
    if (!_inPayload) _endFrame();
    return true;
  }

  void _endFrame() {
    _inPayload = false;
    if (_finalData) _messageBytes = 0;
    _finalData = false;
  }
}
