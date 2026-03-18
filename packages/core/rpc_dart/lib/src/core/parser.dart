// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'errors.dart';
import '../logs/_logs.dart';
import 'protocol.dart';

/// Internal state for parsing incoming gRPC stream data.
///
/// Manages buffering and parse state for fragmented gRPC messages, which may
/// arrive split across fragments or multiple messages per fragment.
final class _MessageParserState {
  /// Current accumulated buffer.
  List<int> buffer = [];

  /// Expected length of the current message (null until the header is read).
  int? expectedMessageLength;

  /// Compression flag for the message being processed.
  bool isCompressed = false;

  /// Resets state so the next message can be processed.
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
  final RpcLogger? _logger;
  final int _maxMessageLength;
  final int _maxBufferedBytes;
  final Uint8List Function(Uint8List payload)? _decompressor;
  final int _maxMessagesPerChunk;

  RpcMessageParser({
    RpcLogger? logger,
    int maxMessageLength = 64 * 1024 * 1024,
    int? maxBufferedBytes,
    Uint8List Function(Uint8List payload)? decompressor,
    int maxMessagesPerChunk = 1024,
  })  : _logger = logger,
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
      _logger?.error(
        'Failed to parse incoming data: $e',
        error: e,
        stackTrace: trace,
      );
      rethrow;
    }
  }

  List<Uint8List> _call(Uint8List data) {
    final result = <Uint8List>[];

    // Append data to the buffer.
    _state.buffer.addAll(data);
    if (_state.buffer.length > _maxBufferedBytes) {
      final buffered = _state.buffer.length;
      _state.buffer.clear();
      _state.reset();
      throw RpcException(
        'gRPC frame buffer overflow: $buffered bytes (max: $_maxBufferedBytes)',
      );
    }

    // Process buffer while messages can be extracted.
    while (_state.buffer.length >= RpcConstants.messagePrefixSize) {
      // If length is unknown yet, extract it from the header.
      if (_state.expectedMessageLength == null) {
        try {
          final header = RpcMessageFrame.parseHeader(
            Uint8List.fromList(
              _state.buffer.sublist(0, RpcConstants.messagePrefixSize),
            ),
          );
          _state.isCompressed = header.isCompressed;
          _state.expectedMessageLength = header.messageLength;

          if (_state.expectedMessageLength! > _maxMessageLength) {
            final length = _state.expectedMessageLength!;
            _state.buffer.clear();
            _state.reset();
            throw RpcException(
              'gRPC frame payload is too large: $length bytes (max: $_maxMessageLength)',
            );
          }

          // Remove the header from the buffer.
          _state.buffer = _state.buffer.sublist(
            RpcConstants.messagePrefixSize,
          );
        } catch (e, trace) {
          _logger?.error(
            'Failed to parse frame header: $e',
            error: e,
            stackTrace: trace,
          );
          _state.buffer.clear();
          _state.reset();
          rethrow;
        }
      }

      // If we have enough data for a complete message.
      if (_state.buffer.length >= _state.expectedMessageLength!) {
        // Extract the message.
        final messageBytes = _state.buffer.sublist(
          0,
          _state.expectedMessageLength!,
        );
        var payload = Uint8List.fromList(messageBytes);
        if (_state.isCompressed) {
          final decompressor = _decompressor;
          if (decompressor == null) {
            // No decompressor at this layer: reconstruct the complete gRPC
            // frame (with compression bit set) and pass it through so the
            // application layer can decompress it.
            payload = RpcMessageFrame.encode(payload, compressed: true);
          } else {
            payload = decompressor(payload);
            if (payload.length > _maxMessageLength) {
              final length = payload.length;
              _state.buffer.clear();
              _state.reset();
              throw RpcException(
                'Decompressed gRPC payload is too large: $length bytes (max: $_maxMessageLength)',
              );
            }
          }
        }
        result.add(payload);
        if (result.length > _maxMessagesPerChunk) {
          _state.buffer.clear();
          _state.reset();
          throw RpcException(
            'Too many gRPC messages in a single chunk: ${result.length} (max: $_maxMessagesPerChunk)',
          );
        }

        // Drop processed bytes from the buffer.
        _state.buffer = _state.buffer.sublist(_state.expectedMessageLength!);

        // Reset for the next message.
        _state.reset();
      } else {
        // Not enough data yet; wait for the next chunk.
        break;
      }
    }

    _logger?.internal(
      'Chunk processed, messages extracted: ${result.length}',
    );
    return result;
  }
}
