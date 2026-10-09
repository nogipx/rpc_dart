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
/// copy. It holds only what a chunk left incomplete; see [RpcMessageParser].
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
  /// Reallocating and copying the UNCONSUMED TAIL on each call is O(N^2/C) while
  /// one message's body is incomplete — a 16 MiB message in 16 KiB chunks is
  /// ~1024 growing copies. Geometric growth is the same shape
  /// `RpcFrameMultiplexedChannel` uses one layer up, for the same reason and with
  /// the same names.
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

  /// Whether bytes of a frame are buffered that no message has been built from
  /// yet — so more input would complete one.
  ///
  /// **An empty result from [call] does NOT mean that.** It also means the frame
  /// was REFUSED: every limit here clears the buffer and throws, so a caller
  /// reading emptiness as "incomplete" reports a truncated request where the
  /// operator's `maxMessageLengthBytes` fired. That is a security control
  /// reporting the wrong thing, and it is why this is a question for the parser
  /// rather than an inference from its output.
  ///
  /// True only after [call] stopped for want of bytes: fewer than five of a
  /// header, or a header whose body has not all arrived. That includes a body
  /// with no byte yet: the header is consumed by then, so nothing is buffered.
  bool get holdsPartialFrame =>
      _state.available > 0 || _state.expectedMessageLength != null;

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
    } catch (e) {
      // Rethrown to the owner, which answers the peer and decides whether this
      // is a fault worth a record. Logging it here too made every refused
      // frame an error, written by whichever peer sent it.
      if (_logger.isInternal) {
        _logger.internal('Failed to parse incoming data: $e');
      }
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
    // Decode straight out of the chunk when nothing is buffered, which is the
    // ordinary case: a chunk that holds whole messages is not copied into the
    // buffer first, and each body is a VIEW into it. Only an incomplete tail is
    // buffered. A view relies on the chunk not being written into after it is
    // handed over -- the rule `IRpcChannel.incoming` states one layer down.
    //
    // A buffered body is still COPIED out: the buffer is compacted and reused,
    // so a view into it would change under the receiver.
    final fromChunk =
        _state.available == 0 && _state.expectedMessageLength == null;
    late Uint8List src;
    var pos = 0;
    var end = 0;
    if (fromChunk) {
      src = data;
      end = data.length;
    } else {
      _state.addBytes(data);
      src = _state._bytes;
      pos = _state.readOffset;
      end = _state._length;
    }

    // Uses an offset instead of slicing — O(1) per iteration, O(remaining)
    // compact at the end instead of O(N²) copies in the loop.
    while (true) {
      // If length is unknown yet, try to extract it from the header.
      if (_state.expectedMessageLength == null) {
        // Need at least 5 bytes to read the header.
        if (end - pos < RpcConstants.messagePrefixSize) break;

        try {
          final header = RpcMessageFrame.parseHeader(
            Uint8List.sublistView(
              src,
              pos,
              pos + RpcConstants.messagePrefixSize,
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
          pos += RpcConstants.messagePrefixSize;
        } catch (_) {
          // Reported once, by [call], which every failure here reaches.
          _state.clear();
          _state.reset();
          rethrow;
        }
      }

      // Need the full body before we can emit the message.
      if (end - pos < _state.expectedMessageLength!) break;

      final bodyEnd = pos + _state.expectedMessageLength!;
      var payload = fromChunk
          ? Uint8List.sublistView(src, pos, bodyEnd)
          : src.sublist(pos, bodyEnd);
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
          // A decompressor that honours the hint aborts with a
          // RESOURCE_EXHAUSTED RpcStatusException, as both gzip codecs do, and
          // that passes through. Anything else it throws -- malformed input, or
          // a third-party codec's own type -- is rewrapped below, because
          // `wireStatusFor` is default-deny and would redact it.
          try {
            payload = decompressor(payload, maxOutputBytes: _maxMessageLength);
          } catch (e) {
            _state.clear();
            _state.reset();
            if (e is RpcException) rethrow;
            // INTERNAL: what reaches here is malformed input, or a third-party
            // codec that signals its limit some other way, and this catch
            // cannot tell those apart. grpc-go answers a decompression failure
            // INTERNAL too.
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
      pos = bodyEnd;

      // Reset for the next message.
      _state.reset();
    }

    if (fromChunk) {
      // The unconsumed tail, whose header may already have been read.
      if (pos < end) _state.addBytes(Uint8List.sublistView(data, pos, end));
    } else {
      _state.readOffset = pos;
      // Single compact at the end: drop all consumed bytes in one O(remaining)
      // copy instead of O(N) copies of shrinking buffer inside the loop above.
      _state.compact();
    }

    if (_logger.isInternal) {
      _logger.internal('Chunk processed, messages extracted: ${result.length}');
    }
    return result;
  }
}
