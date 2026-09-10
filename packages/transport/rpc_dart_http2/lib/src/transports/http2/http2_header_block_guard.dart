// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

/// Bounds the raw size of a single HTTP/2 header block on the receive path.
///
/// A header block is a HEADERS (or PUSH_PROMISE) frame plus the CONTINUATION
/// frames that follow it before one carries the END_HEADERS flag. package:http2
/// concatenates that whole block into one buffer with NO limit -- its
/// `FrameDefragmenter` even carries the standing TODO "emit an error if too
/// many continuation frames have been sent (since we're buffering all of them)"
/// -- and it rebuilds the buffer on every CONTINUATION (`addBlockContinuation`
/// allocates `old + new` and copies both), so N frames cost O(N^2) bytes of
/// memcpy on the connection's read path.
///
/// That read path runs on the server's single event loop, and the block is
/// never handed upward until END_HEADERS, so a peer that opens a header block
/// and never ends it is invisible to every rpc_dart limit (maxActiveStreams,
/// maxHeaders, maxHeaderValueBytes, halfOpenStreamTimeout): no stream is
/// created and no handler is dispatched. This is the HTTP/2 CONTINUATION flood.
///
/// Unguarded, one connection can retain tens of MiB of RSS and starve the event
/// loop for minutes of CPU, because the recopy is quadratic in the number of
/// CONTINUATION frames.
///
/// This transformer watches frame headers only -- it forwards every byte
/// untouched -- and tears the connection down the moment an accumulating header
/// block passes [maxHeaderBlockBytes]. A legitimate gRPC request's header block
/// is well under a kilobyte, so the default bound (the policy's
/// `maxMetadataBytes`, 64 KiB) never touches real traffic.
///
/// [skipConnectionPreface] must be TRUE for a server reading from a client (the
/// 24-octet preface opens that direction) and FALSE for a client reading from a
/// server (which sends frames immediately). Getting it backwards silently
/// disables the guard in one direction and corrupts parsing in the other -- see
/// [_HeaderBlockScanner._connectionPrefaceSize].
///
/// [onGoaway], when given, fires the first time the peer sends a GOAWAY frame.
/// This scanner is the only place in the transport that sees raw frames, and
/// package:http2 exposes no draining signal of its own -- `isOpen` folds GOAWAY
/// together with "at MAX_CONCURRENT_STREAMS" -- so surfacing it here is what
/// lets a caller tell a DRAINING peer (reconnect elsewhere) from a merely
/// SATURATED one (wait for a slot).
///
/// [onPrefaceComplete], when given, fires once the peer has finished sending the
/// preface: the first evidence that an accepted socket is an HTTP/2 client at
/// all. Only meaningful with [skipConnectionPreface] true.
Stream<List<int>> guardHttp2HeaderBlock(
  Stream<List<int>> incoming, {
  required int maxHeaderBlockBytes,
  required void Function(int observedBytes) onViolation,
  bool skipConnectionPreface = true,
  void Function()? onGoaway,
  void Function()? onPrefaceComplete,
}) {
  final controller = StreamController<List<int>>();
  final scanner = _HeaderBlockScanner(
    maxHeaderBlockBytes,
    skipConnectionPreface: skipConnectionPreface,
    onGoaway: onGoaway,
    onPrefaceComplete: onPrefaceComplete,
  );
  late StreamSubscription<List<int>> sub;
  var violated = false;

  sub = incoming.listen(
    (chunk) {
      if (violated) return;
      final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      final observed = scanner.scan(data);
      if (observed != null) {
        violated = true;
        onViolation(observed);
        // End the stream downstream so package:http2 unwinds, and stop reading
        // from the peer. The socket is destroyed by [onViolation].
        unawaited(sub.cancel());
        if (!controller.isClosed) controller.close();
        return;
      }
      if (!controller.isClosed) controller.add(chunk);
    },
    onError: (Object e, StackTrace st) {
      if (!controller.isClosed) controller.addError(e, st);
    },
    onDone: () {
      if (!controller.isClosed) controller.close();
    },
    cancelOnError: false,
  );

  controller.onCancel = () => sub.cancel();
  return controller.stream;
}

/// Tracks HTTP/2 frame boundaries in a byte stream and sums the payload lengths
/// of the frames that make up a single header block.
///
/// Purely observational: it never copies a payload. Within a chunk it either
/// assembles a 9-byte frame header or jumps over a payload span in O(1), so the
/// scan costs O(frames), not O(bytes).
class _HeaderBlockScanner {
  _HeaderBlockScanner(
    this._max, {
    required bool skipConnectionPreface,
    void Function()? onGoaway,
    void Function()? onPrefaceComplete,
  }) : _prefaceRemaining = skipConnectionPreface ? _connectionPrefaceSize : 0,
       _onGoaway = onGoaway,
       _onPrefaceComplete = onPrefaceComplete;

  static const int _frameHeaderSize = 9;
  static const int _typeHeaders = 0x1;
  static const int _typePushPromise = 0x5;
  static const int _typeContinuation = 0x9;
  static const int _flagEndHeaders = 0x4;

  /// GOAWAY, RFC 9113 s6.8. Always on stream 0.
  static const int _typeGoaway = 0x7;

  final void Function()? _onGoaway;
  bool _goawaySeen = false;

  /// Fires once, when the peer has finished sending the connection preface.
  ///
  /// The scanner is the only thing in the transport that sees raw bytes before
  /// package:http2 does, so it is the only place that can tell "this peer has
  /// begun speaking HTTP/2" from "this peer has been accepted". Never fires when
  /// [skipConnectionPreface] is false, because in that direction there is no
  /// preface to complete.
  final void Function()? _onPrefaceComplete;

  /// Length of the client connection preface, RFC 9113 s3.4: the 24-octet
  /// sequence "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" that opens every client-to-
  /// server HTTP/2 connection, BEFORE any frame. It must be consumed before
  /// frame parsing starts, or its first nine bytes ("PRI * HT...") are read as
  /// a bogus frame header declaring a ~5 MiB payload -- which made the scanner
  /// skip the real frames and never fire.
  ///
  /// It is present ONLY in the client-to-server direction, so a server skips it
  /// and a client must not: a client that skipped 24 bytes of the server's
  /// first frames would misparse everything after them.
  static const int _connectionPrefaceSize = 24;

  final int _max;

  int _prefaceRemaining;
  final Uint8List _hdr = Uint8List(_frameHeaderSize);
  int _hdrHave = 0;
  int _payloadRemaining = 0;
  bool _inBlock = false;
  int _blockBytes = 0;

  /// Scans [chunk], updating state. Returns the observed header-block size if it
  /// exceeded the cap during this chunk, else null.
  int? scan(Uint8List chunk) {
    var i = 0;
    final n = chunk.length;
    while (i < n) {
      if (_prefaceRemaining > 0) {
        final available = n - i;
        final skip = available < _prefaceRemaining
            ? available
            : _prefaceRemaining;
        i += skip;
        _prefaceRemaining -= skip;
        if (_prefaceRemaining == 0) _onPrefaceComplete?.call();
        continue;
      }
      if (_payloadRemaining > 0) {
        final available = n - i;
        final skip = available < _payloadRemaining
            ? available
            : _payloadRemaining;
        i += skip;
        _payloadRemaining -= skip;
        continue;
      }

      // Assemble the next 9-byte frame header, possibly across a chunk boundary.
      while (_hdrHave < _frameHeaderSize && i < n) {
        _hdr[_hdrHave++] = chunk[i++];
      }
      if (_hdrHave < _frameHeaderSize) break; // resumes on the next chunk
      _hdrHave = 0;

      final length = (_hdr[0] << 16) | (_hdr[1] << 8) | _hdr[2];
      final type = _hdr[3];
      final flags = _hdr[4];

      if (type == _typeHeaders || type == _typePushPromise) {
        // Starts a fresh header block. If END_HEADERS is already set it is a
        // one-frame block; either way its own payload counts.
        _inBlock = (flags & _flagEndHeaders) == 0;
        _blockBytes = length;
      } else if (type == _typeContinuation) {
        if (_inBlock) {
          _blockBytes += length;
          if ((flags & _flagEndHeaders) != 0) _inBlock = false;
        }
      } else if (type == _typeGoaway && !_goawaySeen) {
        // Reported once. A peer may legitimately send a second GOAWAY with a
        // lower last-stream-id while draining, and the transport only needs to
        // learn "this connection is going away" a single time.
        _goawaySeen = true;
        _onGoaway?.call();
      }

      if ((type == _typeHeaders ||
              type == _typePushPromise ||
              type == _typeContinuation) &&
          _blockBytes > _max) {
        return _blockBytes;
      }

      _payloadRemaining = length;
    }
    return null;
  }
}
