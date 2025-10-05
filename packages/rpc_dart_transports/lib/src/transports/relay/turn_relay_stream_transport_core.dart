// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';

/// Core transport implementation that multiplexes RPC metadata and payload
/// frames over a bidirectional byte stream.
///
/// The transport expects each datagram to carry a 4-byte stream identifier and
/// a one-byte flag field followed by an optional payload. Metadata frames encode
/// [RpcMetadata] as JSON while data frames contain gRPC-framed payloads.
abstract class RpcTurnRelayStreamTransportCore implements IRpcTransport {
  RpcTurnRelayStreamTransportCore({
    required this.componentName,
    required RpcStreamIdManager idManager,
    required Stream<Uint8List> incomingDatagrams,
    required Future<void> Function(Uint8List packet) sendDatagram,
    Future<void> Function()? onClose,
    Future<RpcHealthStatus> Function()? customHealth,
    Future<RpcHealthStatus> Function()? customReconnect,
    RpcLogger? logger,
  })  : _idManager = idManager,
        _sendDatagram = sendDatagram,
        _onClose = onClose,
        _customHealth = customHealth,
        _customReconnect = customReconnect,
        _logger = logger,
        _incomingController =
            StreamController<RpcTransportMessage>.broadcast() {
    _subscription = incomingDatagrams.listen(
      _handleIncomingBytes,
      onError: _handleError,
      onDone: _handleDone,
      cancelOnError: false,
    );
  }

  /// Human readable component name used in health diagnostics.
  final String componentName;

  final RpcStreamIdManager _idManager;
  final Future<void> Function(Uint8List packet) _sendDatagram;
  final Future<void> Function()? _onClose;
  final Future<RpcHealthStatus> Function()? _customHealth;
  final Future<RpcHealthStatus> Function()? _customReconnect;
  final RpcLogger? _logger;
  final StreamController<RpcTransportMessage> _incomingController;

  StreamSubscription<Uint8List>? _subscription;
  final Map<int, RpcMessageParser> _streamParsers = {};
  bool _closed = false;
  bool _closeInvoked = false;

  @override
  bool get isClient => _idManager.isClient;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  int createStream() {
    if (_closed) {
      throw StateError('$componentName is closed');
    }

    return _idManager.generateId();
  }

  @override
  bool releaseStreamId(int streamId) {
    if (_closed) {
      return false;
    }

    _streamParsers.remove(streamId);
    return _idManager.releaseId(streamId);
  }

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {
    if (_closed) {
      return;
    }

    try {
      final metadataJson = <String, Object?>{
        'headers': metadata.headers
            .map((header) => {'name': header.name, 'value': header.value})
            .toList(),
        if (metadata.methodPath != null) 'methodPath': metadata.methodPath,
      };

      final payload = utf8.encode(json.encode(metadataJson));
      await _sendWithHeader(
        streamId,
        Uint8List.fromList(payload),
        isMetadata: true,
        endStream: endStream,
      );
    } catch (error, stackTrace) {
      _logger?.error(
        'Failed to send metadata on stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (_closed) {
      return;
    }

    try {
      final framed = RpcMessageFrame.encode(data);
      await _sendWithHeader(streamId, framed, endStream: endStream);

      if (endStream) {
        _idManager.releaseId(streamId);
      }
    } catch (error, stackTrace) {
      _logger?.error(
        'Failed to send data on stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> finishSending(int streamId) async {
    if (_closed) {
      return;
    }

    try {
      await _sendWithHeader(streamId, Uint8List(0), endStream: true);
      _idManager.releaseId(streamId);
    } catch (error, stackTrace) {
      _logger?.error(
        'Failed to finish stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed && _incomingController.isClosed) {
      return;
    }

    _closed = true;
    _streamParsers.clear();

    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }

    if (!_closeInvoked && _onClose != null) {
      _closeInvoked = true;
      try {
        await _onClose!();
      } catch (error, stackTrace) {
        _logger?.error(
          'Error while closing $componentName: $error',
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: componentName,
        message: '$componentName closed',
      );
    }

    if (_closed) {
      return RpcHealthStatus.degraded(
        component: componentName,
        message: '$componentName connection is closed',
      );
    }

    if (_customHealth != null) {
      return _customHealth!();
    }

    return RpcHealthStatus.healthy(
      component: componentName,
      message: '$componentName ready',
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    if (_customReconnect != null) {
      return _customReconnect!();
    }

    return RpcHealthStatus.degraded(
      component: componentName,
      message: 'Reconnect is not supported for $componentName transports',
      details: const {'supported': false},
    );
  }

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((e) => e.streamId == streamId);
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) {
    throw UnimplementedError();
  }

  Future<void> _sendWithHeader(
    int streamId,
    Uint8List payload, {
    bool isMetadata = false,
    bool endStream = false,
  }) async {
    final header = Uint8List(5);
    header[0] = (streamId >> 24) & 0xFF;
    header[1] = (streamId >> 16) & 0xFF;
    header[2] = (streamId >> 8) & 0xFF;
    header[3] = streamId & 0xFF;

    var flags = 0;
    if (endStream) {
      flags |= 0x01;
    }
    if (isMetadata) {
      flags |= 0x02;
    }
    header[4] = flags;

    final packet = Uint8List(header.length + payload.length);
    packet.setRange(0, header.length, header);
    if (payload.isNotEmpty) {
      packet.setRange(header.length, packet.length, payload);
    }

    await _sendDatagram(packet);
  }

  void _handleIncomingBytes(Uint8List message) {
    if (_closed) {
      return;
    }

    if (message.length < 5) {
      _logger?.warning(
        'Ignoring short frame of ${message.length} bytes in $componentName',
      );
      return;
    }

    final streamId = (message[0] << 24) |
        (message[1] << 16) |
        (message[2] << 8) |
        message[3];
    final flags = message[4];
    final isEndOfStream = (flags & 0x01) != 0;
    final isMetadata = (flags & 0x02) != 0;
    final payload = message.sublist(5);

    if (isMetadata) {
      _handleMetadataMessage(streamId, payload, isEndOfStream);
    } else {
      _handleDataMessage(streamId, payload, isEndOfStream);
    }
  }

  void _handleMetadataMessage(
    int streamId,
    Uint8List payload,
    bool isEndOfStream,
  ) {
    try {
      final jsonStr = utf8.decode(payload);
      final data = json.decode(jsonStr) as Map<String, dynamic>;
      final headers = <RpcHeader>[];

      final rawHeaders = data['headers'];
      if (rawHeaders is List) {
        for (final entry in rawHeaders) {
          if (entry is Map<String, dynamic>) {
            final name = entry['name'];
            final value = entry['value'];
            if (name is String && value is String) {
              headers.add(RpcHeader(name, value));
            }
          }
        }
      }

      final methodPath = data['methodPath'] as String?;
      final metadata = RpcMetadata(headers);
      final message = RpcTransportMessage.withMetadata(
        metadata: metadata,
        isEndOfStream: isEndOfStream,
        methodPath: methodPath,
        streamId: streamId,
      );

      _incomingController.add(message);

      if (isEndOfStream) {
        _streamParsers.remove(streamId);
        _idManager.releaseId(streamId);
      }
    } catch (error, stackTrace) {
      _logger?.error(
        'Failed to decode metadata for stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleDataMessage(
    int streamId,
    Uint8List payload,
    bool isEndOfStream,
  ) {
    try {
      if (isEndOfStream && payload.isEmpty) {
        _incomingController.add(
          RpcTransportMessage(
            streamId: streamId,
            isEndOfStream: true,
          ),
        );
        _streamParsers.remove(streamId);
        _idManager.releaseId(streamId);
        return;
      }

      final parser = _streamParsers.putIfAbsent(
        streamId,
        () => RpcMessageParser(
          logger: _logger?.child('Parser-$streamId'),
        ),
      );

      final messages = parser(payload);
      if (messages.isEmpty) {
        if (isEndOfStream) {
          _incomingController.add(
            RpcTransportMessage(
              streamId: streamId,
              isEndOfStream: true,
            ),
          );
          _streamParsers.remove(streamId);
          _idManager.releaseId(streamId);
        }
        return;
      }

      for (var i = 0; i < messages.length; i++) {
        final chunk = messages[i];
        final isLast = isEndOfStream && i == messages.length - 1;
        _incomingController.add(
          RpcTransportMessage.withPayload(
            payload: chunk,
            isEndOfStream: isLast,
            streamId: streamId,
          ),
        );
      }

      if (isEndOfStream) {
        _streamParsers.remove(streamId);
        _idManager.releaseId(streamId);
      }
    } catch (error, stackTrace) {
      _logger?.error(
        'Failed to decode payload for stream $streamId: $error',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    _logger?.error(
      '$componentName stream error: $error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _handleDone() {
    _logger?.info('$componentName stream closed');
    _closed = true;

    if (!_incomingController.isClosed) {
      _incomingController.close();
    }
  }
}
