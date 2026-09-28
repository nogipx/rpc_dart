// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import '../logger/_index.dart';
import 'errors.dart';
import 'protocol.dart';

/// Internal state for parsing incoming gRPC stream data.
///
/// Manages buffering and parse state for fragmented gRPC messages, which may
/// arrive split across fragments or multiple messages per fragment.
///
/// Uses a [Uint8List] backing buffer and a read-offset pointer to avoid O(N²)
/// copies when multiple gRPC messages arrive in a single chunk. One compact()
/// call at the end of each parse pass drops consumed bytes in a single O(n)
/// copy, and sublist() on a Uint8List produces a typed copy without boxing.
final class _MessageParserState {
  /// Capacity buffer. Only `readOffset..[_length]` is valid data; the rest is
  /// spare room grown geometrically.
  Uint8List _bytes = Uint8List(0);

  /// End of the valid region in [_bytes]. NOT `_bytes.length`, which is capacity.
  int _length = 0;

  /// Index of the first unprocessed byte in [_bytes].
  int readOffset = 0;

  /// Number of bytes not yet consumed.
  int get available => _length - readOffset;

  /// Grows capacity to at least [needed], doubling, and keeps the valid region.
  void _ensureCapacity(int needed) {
    if (needed <= _bytes.length) return;
    var cap = _bytes.isEmpty ? 64 : _bytes.length;
    while (cap < needed) {
      cap *= 2;
    }
    final grown = Uint8List(cap);
    grown.setRange(0, _length, _bytes);
    _bytes = grown;
  }

  /// Appends [data] to the buffer, amortized O(size of data).
  ///
  /// Every version before this one reallocated and copied the UNCONSUMED TAIL on
  /// each call, which is O(N^2/C) while one message's body is incomplete: a
  /// 16 MiB message in 16 KiB chunks is ~1024 growing copies. Measured at a
  /// fixed 16 KiB chunk, cost per KiB doubling with the message:
  ///
  ///     1 MiB    7 ms    6.84 us/KiB
  ///     4 MiB  122 ms   29.79 us/KiB
  ///    16 MiB 1515 ms   92.47 us/KiB
  ///
  /// Geometric growth is the same shape `RpcFrameMultiplexedChannel` uses one
  /// layer up, for the same reason and with the same names.
  void addBytes(Uint8List data) {
    // Reclaim the consumed prefix before growing, so a long-lived stream of
    // whole messages reuses one buffer instead of extending it forever.
    if (readOffset > 0 && readOffset == _length) {
      readOffset = 0;
      _length = 0;
    }
    _ensureCapacity(_length + data.length);
    _bytes.setRange(_length, _length + data.length, data);
    _length += data.length;
  }

  /// Returns a typed copy of bytes [from]..[to] — one copy, no boxing.
  Uint8List sublist(int from, int to) => _bytes.sublist(from, to);

  /// Drops consumed bytes from the front, so the buffer does not grow without
  /// bound across messages.
  ///
  /// Called once per parser invocation rather than per message. With a capacity
  /// buffer this MOVES the unconsumed tail down instead of reallocating, so the
  /// common case — everything consumed — is free.
  void compact() {
    if (readOffset == 0) return;
    final remaining = _length - readOffset;
    if (remaining > 0) {
      _bytes.setRange(0, remaining, _bytes, readOffset);
    }
    _length = remaining;
    readOffset = 0;
  }

  /// Advances the read pointer by [n] bytes without copying.
  void advance(int n) => readOffset += n;

  /// Clears all buffered data and resets the read pointer.
  void clear() {
    _bytes = Uint8List(0);
    _length = 0;
    readOffset = 0;
  }

  /// Expected length of the current message (null until the header is read).
  int? expectedMessageLength;

  /// Compression flag for the message being processed.
  bool isCompressed = false;

  /// Resets per-message state so the next message can be processed.
  void reset() {
    expectedMessageLength = null;
    isCompressed = false;
  }
}

/// Parser that reassembles fragmented gRPC messages.
///
/// Collects full messages from HTTP/2 DATA frames where gRPC payloads may not
/// align with frame boundaries.
final class RpcMessageParser {
  final LogScope _logger;
  final int _maxMessageLength;
  final int _maxBufferedBytes;
  final Uint8List Function(Uint8List payload, {int? maxOutputBytes})?
  _decompressor;
  final int _maxMessagesPerChunk;

  /// Emit complete gRPC FRAMES rather than bare bodies. See `emitFramed`.
  final bool _emitFramed;

  /// Creates an [RpcMessageParser] with the given configuration.
  ///
  /// The [decompressor], when provided, receives a `maxOutputBytes` hint equal
  /// to [maxMessageLength] so it can bound decompression and reject
  /// decompression bombs before fully materializing the output.
  ///
  /// [emitFramed] makes every emitted value a complete gRPC frame instead of a
  /// bare message body. Off by default, which is what the stream layer wants: it
  /// holds a codec and takes a body. The transports that hand frames upward say
  /// so — currently http2, both directions.
  ///
  /// **It exists because the answer was otherwise unknowable to the caller.**
  /// With no [decompressor] this parser cannot de-frame a compressed message, so
  /// it re-frames the payload and emits a FRAME; for an uncompressed one it emits
  /// a BODY. A caller receiving both had to guess which it held, and the only
  /// evidence available was the bytes — a heuristic over peer-chosen data that
  /// fired on any body whose first five bytes declared its own remaining length,
  /// silently turning a 13-byte message into an 8-byte one (B-78). Removing the
  /// guess without this flag broke every compressed message instead.
  RpcMessageParser({
    LogScope? logger,
    int maxMessageLength = 64 * 1024 * 1024,
    int? maxBufferedBytes,
    Uint8List Function(Uint8List payload, {int? maxOutputBytes})? decompressor,
    int maxMessagesPerChunk = 1024,
    bool emitFramed = false,
  }) : _logger = logger ?? LogScope.noop,
       _maxMessageLength = maxMessageLength,
       _maxBufferedBytes =
           maxBufferedBytes ??
           (maxMessageLength + RpcConstants.messagePrefixSize),
       _decompressor = decompressor,
       _maxMessagesPerChunk = maxMessagesPerChunk,
       _emitFramed = emitFramed;

  /// Internal parser state.
  final _MessageParserState _state = _MessageParserState();

  /// Processes an incoming data fragment and returns complete messages.
  ///
  /// Accumulates data in a buffer and uses the 5-byte prefix to extract
  /// complete messages. Can emit multiple messages from one fragment or keep
  /// buffering until a full message is available.
  ///
  /// [data] New chunk of incoming data.
  /// Returns the list of complete messages extracted.
  List<Uint8List> call(Uint8List data) {
    try {
      return _call(data);
    } catch (e, trace) {
      _logger.error(
        'Failed to parse incoming data: $e',
        error: e,
        stackTrace: trace,
      );
      rethrow;
    }
  }

  List<Uint8List> _call(Uint8List data) {
    final result = <Uint8List>[];

    // Checked BEFORE the append, which is the whole point: the buffer grows
    // GEOMETRICALLY now, so appending first lets a peer past the bound make us
    // allocate up to twice it before the bound is consulted. The limit exists to
    // cap what is allocated, not only what is retained — the same order
    // `RpcFrameMultiplexedChannel` uses one layer up, and for the same reason.
    if (_state.available + data.length > _maxBufferedBytes) {
      final buffered = _state.available + data.length;
      _state.clear();
      _state.reset();
      // RESOURCE_EXHAUSTED on the TYPE, not inferred downstream. The http2
      // responder used to read `error is RpcException` to mean "a resource
      // limit" and enumerate these four by hand in a comment — but that is the
      // BASE of the whole hierarchy, so malformed framing raised on the same
      // path matched it too and a corrupt frame came back retryable.
      throw RpcStatusException(
        RpcStatus.resourceExhausted,
        'gRPC frame buffer overflow: $buffered bytes (max: $_maxBufferedBytes)',
      );
    }
    _state.addBytes(data);

    // Process buffer while messages can be extracted.
    // Uses readOffset instead of slicing — O(1) per iteration, O(remaining)
    // compact at the end instead of O(N²) copies in the loop.
    while (true) {
      // If length is unknown yet, try to extract it from the header.
      if (_state.expectedMessageLength == null) {
        // Need at least 5 bytes to read the header.
        if (_state.available < RpcConstants.messagePrefixSize) break;

        try {
          final header = RpcMessageFrame.parseHeader(
            _state.sublist(
              _state.readOffset,
              _state.readOffset + RpcConstants.messagePrefixSize,
            ),
          );
          _state.isCompressed = header.isCompressed;
          _state.expectedMessageLength = header.messageLength;

          if (_state.expectedMessageLength! > _maxMessageLength) {
            final length = _state.expectedMessageLength!;
            _state.clear();
            _state.reset();
            throw RpcStatusException(
              RpcStatus.resourceExhausted,
              'gRPC frame payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }

          // Advance past the header — no copy.
          _state.advance(RpcConstants.messagePrefixSize);
        } catch (e, trace) {
          _logger.error(
            'Failed to parse frame header: $e',
            error: e,
            stackTrace: trace,
          );
          _state.clear();
          _state.reset();
          rethrow;
        }
      }

      // Need the full body before we can emit the message.
      if (_state.available < _state.expectedMessageLength!) break;

      // Extract the message body — one typed copy of exactly the payload bytes.
      var payload = _state.sublist(
        _state.readOffset,
        _state.readOffset + _state.expectedMessageLength!,
      );
      // Whether `payload` is already a complete frame rather than a bare body.
      // Only the compressed-without-a-decompressor branch makes it one, and
      // [_emitFramed] needs to know so it does not wrap it twice -- which loses
      // the compression bit and is what round 455 shipped.
      var alreadyFramed = false;
      if (_state.isCompressed) {
        final decompressor = _decompressor;
        if (decompressor == null) {
          // No decompressor at this layer: reconstruct the complete gRPC
          // frame (with compression bit set) and pass it through so the
          // application layer can decompress it.
          payload = RpcMessageFrame.encode(payload, compressed: true);
          alreadyFramed = true;
        } else {
          // Pass the message-size limit so the decompressor can abort a
          // decompression bomb before fully expanding it. The post-check below
          // remains as a backstop for decompressors that ignore the hint.
          // A decompressor that honours the hint aborts by throwing, and it
          // throws whatever ITS library uses -- FormatException from the gzip
          // codecs, anything at all from a third-party one. `wireStatusFor` is
          // default-deny, so such a type is redacted and the peer is told only
          // "Internal server error" for a message IT can fix by sending less.
          //
          // The limit is this layer's, so the diagnostic should be too: rewrap
          // as an RpcException naming the configured maximum. That keeps the
          // message library-authored (no user data, and provably ours) while
          // staying independent of whatever the codec chose to throw.
          try {
            payload = decompressor(payload, maxOutputBytes: _maxMessageLength);
          } catch (e) {
            _state.clear();
            _state.reset();
            if (e is RpcException) rethrow;
            // NOT "exceeds the limit". A decompressor throws for the bomb it
            // was asked to stop AND for input that is malformed, truncated or
            // not compressed at all, and this catch cannot tell them apart --
            // so naming one of them told a peer with a corrupt frame to send
            // less, which cannot help. State the fact and leave the cause to
            // the two possibilities that produce it.
            //
            // INTERNAL, not RESOURCE_EXHAUSTED, for the reason above: the
            // status is a claim about the CAUSE and this site has two. grpc-go
            // answers a decompression failure INTERNAL ("failed to decompress
            // the received message") and keeps RESOURCE_EXHAUSTED for the sizes
            // it can actually measure, which is the split used here.
            throw RpcStatusException(
              RpcStatus.internal,
              'Compressed gRPC payload could not be decompressed: it is '
              'malformed, or it expands beyond the configured limit '
              '(max: $_maxMessageLength)',
            );
          }
          if (payload.length > _maxMessageLength) {
            final length = payload.length;
            _state.clear();
            _state.reset();
            throw RpcStatusException(
              RpcStatus.resourceExhausted,
              'Decompressed gRPC payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }
        }
      }
      result.add(
        _emitFramed && !alreadyFramed
            ? RpcMessageFrame.encode(payload, compressed: false)
            : payload,
      );
      if (result.length > _maxMessagesPerChunk) {
        _state.clear();
        _state.reset();
        throw RpcStatusException(
          RpcStatus.resourceExhausted,
          'Too many gRPC messages in a single chunk: ${result.length} (max: $_maxMessagesPerChunk)',
        );
      }

      // Advance past the body — no copy.
      _state.advance(_state.expectedMessageLength!);

      // Reset for the next message.
      _state.reset();
    }

    // Single compact at the end: drop all consumed bytes in one O(remaining) copy
    // instead of O(N) copies of shrinking buffer inside the loop above.
    _state.compact();

    if (_logger.isInternal) {
      _logger.internal('Chunk processed, messages extracted: ${result.length}');
    }
    return result;
  }
}
