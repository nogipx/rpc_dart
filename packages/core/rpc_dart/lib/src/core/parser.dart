// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import '../logger/_index.dart';
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
  /// Accumulated byte buffer. May contain already-consumed bytes before [readOffset].
  Uint8List _bytes = Uint8List(0);

  /// Index of the first unprocessed byte in [_bytes].
  int readOffset = 0;

  /// Number of bytes not yet consumed.
  int get available => _bytes.length - readOffset;

  /// Appends [data] to the buffer.
  ///
  /// When the buffer is fully consumed, the new data is taken directly (one
  /// copy). When there are unconsumed bytes, they are concatenated with the
  /// new data (one copy of combined bytes, no boxing).
  void addBytes(Uint8List data) {
    if (readOffset == _bytes.length) {
      // All previous bytes consumed — reuse incoming data directly.
      _bytes = Uint8List.fromList(data);
      readOffset = 0;
    } else {
      // Concat unconsumed tail + new data in a single allocation.
      final unconsumed = _bytes.length - readOffset;
      final merged = Uint8List(unconsumed + data.length);
      merged.setRange(0, unconsumed, _bytes, readOffset);
      merged.setRange(unconsumed, merged.length, data);
      _bytes = merged;
      readOffset = 0;
    }
  }

  /// Returns a typed copy of bytes [from]..[to] — one copy, no boxing.
  Uint8List sublist(int from, int to) => _bytes.sublist(from, to);

  /// Advances the read pointer by [n] bytes without copying.
  void advance(int n) => readOffset += n;

  /// Drops consumed bytes from the front. Called once per parser invocation
  /// instead of slicing on every message — O(remaining) total instead of O(N²).
  void compact() {
    if (readOffset > 0) {
      _bytes = _bytes.sublist(readOffset);
      readOffset = 0;
    }
  }

  /// Clears all buffered data and resets the read pointer.
  void clear() {
    _bytes = Uint8List(0);
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

  /// Creates an [RpcMessageParser] with the given configuration.
  ///
  /// The [decompressor], when provided, receives a `maxOutputBytes` hint equal
  /// to [maxMessageLength] so it can bound decompression and reject
  /// decompression bombs before fully materializing the output.
  RpcMessageParser({
    LogScope? logger,
    int maxMessageLength = 64 * 1024 * 1024,
    int? maxBufferedBytes,
    Uint8List Function(Uint8List payload, {int? maxOutputBytes})? decompressor,
    int maxMessagesPerChunk = 1024,
  })  : _logger = logger ?? LogScope.noop,
        _maxMessageLength = maxMessageLength,
        _maxBufferedBytes = maxBufferedBytes ??
            (maxMessageLength + RpcConstants.messagePrefixSize),
        _decompressor = decompressor,
        _maxMessagesPerChunk = maxMessagesPerChunk;

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

    // Append incoming data to the buffer.
    _state.addBytes(data);
    if (_state.available > _maxBufferedBytes) {
      final buffered = _state.available;
      _state.clear();
      _state.reset();
      throw RpcException(
        'gRPC frame buffer overflow: $buffered bytes (max: $_maxBufferedBytes)',
      );
    }

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
            throw RpcException(
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
      if (_state.isCompressed) {
        final decompressor = _decompressor;
        if (decompressor == null) {
          // No decompressor at this layer: reconstruct the complete gRPC
          // frame (with compression bit set) and pass it through so the
          // application layer can decompress it.
          payload = RpcMessageFrame.encode(payload, compressed: true);
        } else {
          // Pass the message-size limit so the decompressor can abort a
          // decompression bomb before fully expanding it. The post-check below
          // remains as a backstop for decompressors that ignore the hint.
          payload = decompressor(payload, maxOutputBytes: _maxMessageLength);
          if (payload.length > _maxMessageLength) {
            final length = payload.length;
            _state.clear();
            _state.reset();
            throw RpcException(
              'Decompressed gRPC payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }
        }
      }
      result.add(payload);
      if (result.length > _maxMessagesPerChunk) {
        _state.clear();
        _state.reset();
        throw RpcException(
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

    _logger.internal(
      'Chunk processed, messages extracted: ${result.length}',
    );
    return result;
  }
}
