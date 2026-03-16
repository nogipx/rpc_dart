// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ---------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------
//
// Every WebSocket binary message starts with a 5-byte frame header:
//
//   [streamId : 4 bytes, big-endian uint32]
//   [flags    : 1 byte]
//     bit 0 – endStream
//     bit 1 – metadata frame (payload is WsMetadataCodec CBOR)
//     bit 2 – chunked data (payload has an 8-byte chunk header)
//
// DATA frame payload  – gRPC-framed bytes (5-byte prefix + message payload).
//                       Frames may be split across WebSocket messages and are
//                       reassembled by RpcMessageParser.
//
// METADATA frame payload – CBOR-encoded map (RFC 7049, via CborCodec):
//
//   {
//     "p": "/Service/Method",          // methodPath, absent if null
//     "h": [["name","value"], ...]      // headers as array of 2-element arrays
//   }
//
// CHUNKED DATA frame payload:
//
//   [chunk_index : 2 bytes, big-endian uint16]
//   [chunk_count : 2 bytes, big-endian uint16]
//   [chunk_len   : 4 bytes, big-endian uint32]
//   [chunk_data  : chunk_len bytes]

// ---------------------------------------------------------------------------
// Metadata CBOR codec
// ---------------------------------------------------------------------------

/// Encodes/decodes WebSocket metadata frames using CBOR (RFC 7049).
///
/// Uses [CborCodec] from `rpc_dart` — no external dependencies.
/// More compact and self-describing compared to JSON.
abstract final class WsMetadataCodec {
  static const _keyPath = 'p';
  static const _keyHeaders = 'h';

  /// Encodes [metadata] into CBOR bytes.
  static Uint8List encode(RpcMetadata metadata) {
    final map = <String, dynamic>{};

    final path = metadata.methodPath;
    if (path != null && path.isNotEmpty) {
      map[_keyPath] = path;
    }

    map[_keyHeaders] = [
      for (final h in metadata.headers) [h.name, h.value],
    ];

    return CborCodec.encode(map);
  }

  /// Decodes CBOR [bytes] into metadata and an optional method path.
  ///
  /// Returns `null` if the bytes are malformed.
  static ({RpcMetadata metadata, String? methodPath})? decode(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    try {
      final map = CborCodec.decode(bytes);

      final pathRaw = map[_keyPath];
      final methodPath = pathRaw is String && pathRaw.isNotEmpty
          ? pathRaw
          : null;

      final headersRaw = map[_keyHeaders];
      final headers = <RpcHeader>[];
      if (headersRaw is List) {
        for (final item in headersRaw) {
          if (item is List && item.length >= 2) {
            final name = item[0];
            final value = item[1];
            if (name is String && value is String) {
              headers.add(RpcHeader(name, value));
            }
          }
        }
      }

      final metadata = RpcMetadata(headers, methodPath: methodPath);
      return (metadata: metadata, methodPath: methodPath);
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Transport base
// ---------------------------------------------------------------------------

/// WebSocket transport base. Compatible with dart2js/Wasm.
///
/// Wire format: see the file-level comment above.
abstract class RpcWebSocketTransportBase implements IRpcTransport {
  WebSocketChannel _channel;
  final Future<WebSocketChannel> Function()? _reconnectFactory;
  StreamSubscription? _channelSubscription;
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();
  final Map<int, RpcMessageParser> _streamParsers = {};
  final Map<int, _ChunkAssembly> _chunkAssemblies = {};
  final Set<int> _activeStreams = <int>{};
  bool _closed = false;
  final RpcLogger? _logger;

  final int _chunkSizeBytes;
  final int _maxChunkedMessageBytes;
  final int _maxWebSocketMessageBytes;
  final int _maxMessageLengthBytes;
  final int? _maxBufferedBytes;
  final int _maxMessagesPerChunk;
  final int _maxMetadataBytes;
  final int _maxHeaders;
  final int _maxHeaderNameBytes;
  final int _maxHeaderValueBytes;
  final int _maxActiveStreams;
  final int _maxChunkCount;
  final int _maxMethodPathLength;
  final bool _closeOnProtocolError;
  final bool _enableChunking;

  RpcWebSocketTransportBase(
    WebSocketChannel channel, {
    RpcLogger? logger,
    Future<WebSocketChannel> Function()? reconnectFactory,
    int chunkSizeBytes = 64 * 1024,
    RpcSecurityPolicy policy = const RpcSecurityPolicy(),
    bool enableChunking = false,
  }) : _channel = channel,
       _reconnectFactory = reconnectFactory,
       _logger = logger,
       _chunkSizeBytes = chunkSizeBytes > 0 ? chunkSizeBytes : 64 * 1024,
       _maxChunkedMessageBytes = policy.maxChunkedMessageBytes,
       _maxWebSocketMessageBytes = policy.maxWebSocketMessageBytes,
       _maxMessageLengthBytes = policy.maxMessageLengthBytes,
       _maxBufferedBytes = policy.maxBufferedBytes,
       _maxMessagesPerChunk = policy.maxMessagesPerChunk,
       _maxMetadataBytes = policy.maxMetadataBytes,
       _maxHeaders = policy.maxHeaders,
       _maxHeaderNameBytes = policy.maxHeaderNameBytes,
       _maxHeaderValueBytes = policy.maxHeaderValueBytes,
       _maxActiveStreams = policy.maxActiveStreams,
       _maxChunkCount = policy.maxChunkCount,
       _maxMethodPathLength = policy.maxMethodPathLength,
       _closeOnProtocolError = policy.closeOnProtocolError,
       _enableChunking = enableChunking {
    _setupListener();
  }

  RpcStreamIdManager get idManager;

  @override
  bool get isClient;

  @override
  bool get isClosed => _closed;

  void _setupListener() {
    _channelSubscription?.cancel();
    _channelSubscription = _channel.stream.listen(
      _handleIncomingMessage,
      onError: _handleError,
      onDone: _handleDone,
    );
    _closed = false;
  }

  void _handleIncomingMessage(dynamic message) {
    if (_closed) return;
    try {
      if (message is! List<int>) return;
      final bytes = Uint8List.fromList(message);
      if (bytes.length > _maxWebSocketMessageBytes) {
        _protocolViolation(
          'WebSocket message too large: ${bytes.length} > $_maxWebSocketMessageBytes',
        );
        return;
      }
      if (bytes.length < 5) {
        _protocolViolation('WebSocket message too short: ${bytes.length}');
        return;
      }
      final streamId =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (streamId <= 0) {
        _protocolViolation('Invalid streamId: $streamId');
        return;
      }
      final flags = bytes[4];
      final isEndOfStream = (flags & 0x01) != 0;
      final isMetadata = (flags & 0x02) != 0;
      final isChunked = (flags & 0x04) != 0;
      final payload = bytes.sublist(5);
      if (isMetadata) {
        _handleMetadataMessage(streamId, payload, isEndOfStream);
      } else {
        _handleDataMessage(
          streamId,
          payload,
          isEndOfStream,
          isChunked: isChunked,
        );
      }
    } catch (e, st) {
      _logger?.error('handleIncoming failed: $e', error: e, stackTrace: st);
    }
  }

  void _handleMetadataMessage(
    int streamId,
    Uint8List payload,
    bool isEndOfStream,
  ) {
    if (payload.length > _maxMetadataBytes) {
      _protocolViolation(
        'Metadata payload too large: ${payload.length} > $_maxMetadataBytes',
      );
      return;
    }
    if (_activeStreams.length >= _maxActiveStreams &&
        !_activeStreams.contains(streamId)) {
      _protocolViolation(
        'Too many active streams: ${_activeStreams.length} (max: $_maxActiveStreams)',
      );
      return;
    }

    final decoded = WsMetadataCodec.decode(payload);
    if (decoded == null) {
      _protocolViolation('Malformed metadata frame (stream $streamId)');
      return;
    }

    final methodPath = decoded.methodPath;
    if (methodPath != null &&
        (methodPath.isEmpty ||
            methodPath.length > _maxMethodPathLength ||
            !methodPath.startsWith('/'))) {
      _protocolViolation('Invalid methodPath in metadata (stream $streamId)');
      return;
    }

    // Validate headers.
    for (final h in decoded.metadata.headers) {
      if (!_isValidHeaderName(h.name) || !_isValidHeaderValue(h.value)) {
        _protocolViolation('Invalid header in metadata (stream $streamId)');
        return;
      }
    }
    if (decoded.metadata.headers.length > _maxHeaders) {
      _protocolViolation(
        'Too many headers in metadata (stream $streamId): '
        '${decoded.metadata.headers.length} > $_maxHeaders',
      );
      return;
    }

    _incomingController.add(
      RpcTransportMessage(
        streamId: streamId,
        metadata: decoded.metadata,
        isEndOfStream: isEndOfStream,
        methodPath: methodPath,
      ),
    );
    _activeStreams.add(streamId);
    if (isEndOfStream) _onStreamEnd(streamId);
  }

  void _handleDataMessage(
    int streamId,
    Uint8List payload,
    bool isEndOfStream, {
    required bool isChunked,
  }) {
    if (isChunked) {
      _handleChunkedData(streamId, payload, isEndOfStream);
      return;
    }
    if (isEndOfStream && payload.isEmpty) {
      _incomingController.add(
        RpcTransportMessage(streamId: streamId, isEndOfStream: true),
      );
      _onStreamEnd(streamId);
      return;
    }
    if (_streamParsers.length >= _maxActiveStreams &&
        !_streamParsers.containsKey(streamId)) {
      _protocolViolation(
        'Too many active stream parsers: ${_streamParsers.length} (max: $_maxActiveStreams)',
      );
      return;
    }
    final parser = _streamParsers.putIfAbsent(
      streamId,
      () => RpcMessageParser(
        logger: _logger?.child('Parser-$streamId'),
        maxMessageLength: _maxMessageLengthBytes,
        maxBufferedBytes: _maxBufferedBytes,
        maxMessagesPerChunk: _maxMessagesPerChunk,
      ),
    );
    final messages = parser(payload);
    for (final msgData in messages) {
      // Re-wrap as a complete gRPC frame so the app layer (base_processor)
      // receives the same format as the HTTP/2 transport.
      final framedMessage = _ensureGrpcFrame(msgData);
      _incomingController.add(
        RpcTransportMessage(
          streamId: streamId,
          payload: framedMessage,
          isEndOfStream: isEndOfStream && msgData == messages.last,
        ),
      );
    }
    if (isEndOfStream) _onStreamEnd(streamId);
  }

  void _handleChunkedData(int streamId, Uint8List payload, bool isEndOfStream) {
    const chunkHeaderSize = 8;
    if (payload.length < chunkHeaderSize) {
      _protocolViolation('Chunked payload too short (${payload.length})');
      return;
    }
    final chunkIndex = (payload[0] << 8) | payload[1];
    final chunkCount = (payload[2] << 8) | payload[3];
    final declaredLen =
        (payload[4] << 24) |
        (payload[5] << 16) |
        (payload[6] << 8) |
        payload[7];
    if (chunkCount == 0 ||
        chunkIndex >= chunkCount ||
        chunkCount > _maxChunkCount) {
      _protocolViolation(
        'Invalid chunk params index=$chunkIndex count=$chunkCount',
      );
      return;
    }
    final data = payload.sublist(chunkHeaderSize);
    if (data.length != declaredLen) {
      _protocolViolation(
        'Chunk length mismatch (declared $declaredLen, actual ${data.length})',
      );
      return;
    }
    final assembly = _chunkAssemblies.putIfAbsent(
      streamId,
      () => _ChunkAssembly(chunkCount),
    );
    if (assembly.chunkCount != chunkCount) {
      _protocolViolation('Inconsistent chunkCount for stream $streamId');
      _chunkAssemblies.remove(streamId);
      return;
    }
    if (assembly.received[chunkIndex] != null) {
      _protocolViolation('Duplicate chunk $chunkIndex for stream $streamId');
      return;
    }
    final nextTotal = assembly.totalBytes + data.length;
    if (nextTotal > _maxChunkedMessageBytes) {
      _logger?.error(
        'Chunked message too large for stream $streamId: $nextTotal > $_maxChunkedMessageBytes',
      );
      _chunkAssemblies.remove(streamId);
      return;
    }
    assembly.received[chunkIndex] = data;
    assembly.totalBytes = nextTotal;
    assembly.completedChunks += 1;
    if (assembly.completedChunks < assembly.chunkCount) return;

    final builder = BytesBuilder(copy: false);
    for (final chunk in assembly.received) {
      if (chunk == null) {
        _logger?.warning('Missing chunk while assembling stream $streamId');
        _chunkAssemblies.remove(streamId);
        return;
      }
      builder.add(chunk);
    }
    _chunkAssemblies.remove(streamId);
    final merged = builder.takeBytes();
    _handleDataMessage(streamId, merged, isEndOfStream, isChunked: false);
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _logger?.error(
      'WebSocket error: $error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _handleDone() {
    _channelSubscription = null;
    _closed = true;
    if (_reconnectFactory == null) {
      close();
    }
  }

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  Map<String, Object?> _healthDetails() => {
    'isClosed': _closed,
    'incomingControllerClosed': _incomingController.isClosed,
    'activeParsers': _streamParsers.length,
    'reconnectSupported': _reconnectFactory != null,
  };

  @override
  Future<RpcHealthStatus> health() async {
    final details = _healthDetails();
    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'WebSocket transport closed',
        details: details,
      );
    }
    if (_closed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: _reconnectFactory != null
            ? 'WebSocket waiting reconnect'
            : 'WebSocket transport closed',
        details: details,
      );
    }
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'WebSocket transport ready',
      details: details,
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'WebSocket transport closed',
        details: {..._healthDetails(), 'supported': _reconnectFactory != null},
      );
    }
    if (_reconnectFactory == null) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Reconnect is not configured',
        details: {..._healthDetails(), 'supported': false},
      );
    }
    try {
      await _channel.sink.close();
    } catch (_) {}
    if (_channelSubscription != null) {
      await _channelSubscription!.cancel();
      _channelSubscription = null;
    }
    _streamParsers.clear();
    _chunkAssemblies.clear();
    _activeStreams.clear();
    try {
      _channel = await _reconnectFactory();
    } catch (error, st) {
      _logger?.error('Reconnect failed: $error', error: error, stackTrace: st);
      _closed = true;
      return RpcHealthStatus.unhealthy(
        component: runtimeType.toString(),
        message: 'Failed to reconnect WebSocket transport: $error',
        details: {..._healthDetails(), 'supported': true, 'error': '$error'},
      );
    }
    _setupListener();
    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'WebSocket reconnected',
      details: {..._healthDetails(), 'supported': true},
    );
  }

  @override
  int createStream() {
    if (_closed) {
      throw StateError('WebSocket transport closed');
    }
    final streamId = idManager.generateId();
    _activeStreams.add(streamId);
    return streamId;
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_closed) return false;
    _streamParsers.remove(streamId);
    _chunkAssemblies.remove(streamId);
    _activeStreams.remove(streamId);
    return idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    final payload = WsMetadataCodec.encode(metadata);
    if (payload.length > _maxMetadataBytes) {
      throw StateError(
        'Metadata payload too large: ${payload.length} > $_maxMetadataBytes',
      );
    }
    await _sendWithHeader(
      streamId,
      payload,
      isMetadata: true,
      endStream: endStream,
    );
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) return;
    // [data] is already a gRPC frame (5-byte prefix + payload) — send as-is.
    if (_enableChunking && data.length > _chunkSizeBytes) {
      await _sendChunked(streamId, data, endStream: endStream);
    } else {
      if (data.length + 5 > _maxWebSocketMessageBytes) {
        throw StateError(
          'Message exceeds maxWebSocketMessageBytes: ${data.length + 5} > $_maxWebSocketMessageBytes',
        );
      }
      await _sendWithHeader(streamId, data, endStream: endStream);
    }
    if (endStream) _onStreamEnd(streamId);
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) return;
    await _sendWithHeader(streamId, Uint8List(0), endStream: true);
  }

  Future<void> _sendWithHeader(
    int streamId,
    Uint8List payload, {
    bool isMetadata = false,
    bool endStream = false,
    bool isChunked = false,
    int chunkIndex = 0,
    int chunkCount = 1,
  }) async {
    final header = Uint8List(5);
    header[0] = (streamId >> 24) & 0xFF;
    header[1] = (streamId >> 16) & 0xFF;
    header[2] = (streamId >> 8) & 0xFF;
    header[3] = streamId & 0xFF;
    var flags = 0;
    if (endStream) flags |= 0x01;
    if (isMetadata) flags |= 0x02;
    if (isChunked) flags |= 0x04;
    header[4] = flags;

    Uint8List message;
    if (isChunked) {
      final chunkHeader = Uint8List(8);
      chunkHeader[0] = (chunkIndex >> 8) & 0xFF;
      chunkHeader[1] = chunkIndex & 0xFF;
      chunkHeader[2] = (chunkCount >> 8) & 0xFF;
      chunkHeader[3] = chunkCount & 0xFF;
      final chunkLen = payload.length;
      chunkHeader[4] = (chunkLen >> 24) & 0xFF;
      chunkHeader[5] = (chunkLen >> 16) & 0xFF;
      chunkHeader[6] = (chunkLen >> 8) & 0xFF;
      chunkHeader[7] = chunkLen & 0xFF;

      message = Uint8List(header.length + chunkHeader.length + payload.length);
      message.setRange(0, header.length, header);
      message.setRange(
        header.length,
        header.length + chunkHeader.length,
        chunkHeader,
      );
      message.setRange(
        header.length + chunkHeader.length,
        message.length,
        payload,
      );
    } else {
      message = Uint8List(header.length + payload.length);
      message.setRange(0, header.length, header);
      message.setRange(header.length, message.length, payload);
    }

    if (message.length > _maxWebSocketMessageBytes) {
      throw StateError(
        'WebSocket message exceeds maxWebSocketMessageBytes: ${message.length} > $_maxWebSocketMessageBytes',
      );
    }
    _channel.sink.add(message);
  }

  Future<void> _sendChunked(
    int streamId,
    Uint8List payload, {
    required bool endStream,
  }) async {
    final totalLength = payload.length;
    final chunkCount = (totalLength / _chunkSizeBytes).ceil();
    if (chunkCount > 0xFFFF) {
      throw StateError('Too many chunks ($chunkCount > 65535)');
    }
    if (chunkCount > _maxChunkCount) {
      throw StateError('Chunking exceeds maxChunkCount ($chunkCount)');
    }
    var offset = 0;
    for (var idx = 0; idx < chunkCount; idx++) {
      final remaining = totalLength - offset;
      final len = remaining > _chunkSizeBytes ? _chunkSizeBytes : remaining;
      final chunk = Uint8List.sublistView(payload, offset, offset + len);
      offset += len;
      await _sendWithHeader(
        streamId,
        chunk,
        isChunked: true,
        chunkIndex: idx,
        chunkCount: chunkCount,
        endStream: endStream && idx == chunkCount - 1,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed && _incomingController.isClosed) return;
    _closed = true;
    _streamParsers.clear();
    _chunkAssemblies.clear();
    _activeStreams.clear();
    final subscription = _channelSubscription;
    _channelSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    try {
      await _channel.sink.close();
    } finally {
      if (!_incomingController.isClosed) {
        await _incomingController.close();
      }
    }
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnimplementedError('Direct object sending is unsupported');
  }

  void _onStreamEnd(int streamId) {
    _streamParsers.remove(streamId);
    _chunkAssemblies.remove(streamId);
    _activeStreams.remove(streamId);
    final isLocallyInitiated = isClient ? streamId.isOdd : streamId.isEven;
    if (isLocallyInitiated) {
      idManager.releaseId(streamId);
    }
  }

  void _protocolViolation(String message) {
    _logger?.warning('WebSocket protocol violation: $message');
    if (_closeOnProtocolError) {
      unawaited(close());
    }
  }

  bool _isValidHeaderName(String name) {
    if (name.isEmpty || name.length > _maxHeaderNameBytes) return false;
    for (final unit in name.codeUnits) {
      if (unit <= 0x20 || unit == 0x7F) return false;
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
    }
    return true;
  }

  bool _isValidHeaderValue(String value) {
    if (value.length > _maxHeaderValueBytes) return false;
    for (final unit in value.codeUnits) {
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) return false;
    }
    return true;
  }
}

/// Returns [data] unchanged if it is already a valid gRPC frame; otherwise
/// wraps it in an uncompressed gRPC frame.
Uint8List _ensureGrpcFrame(Uint8List data) {
  if (data.length >= RpcConstants.messagePrefixSize) {
    try {
      final header = RpcMessageFrame.parseHeader(data);
      if (RpcConstants.messagePrefixSize + header.messageLength ==
          data.length) {
        return data;
      }
    } catch (_) {}
  }
  return RpcMessageFrame.encode(data, compressed: false);
}

class _ChunkAssembly {
  _ChunkAssembly(this.chunkCount)
    : received = List<Uint8List?>.filled(chunkCount, null, growable: false);

  final int chunkCount;
  final List<Uint8List?> received;
  int completedChunks = 0;
  int totalBytes = 0;
}
