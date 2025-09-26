// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'turn_relay_client.dart';

/// Base transport that multiplexes gRPC metadata and payload frames over a
/// [`TurnRelayClient`] connection.
///
/// The transport reuses the lightweight framing scheme adopted by the
/// WebSocket transport: every datagram consists of a 4-byte stream identifier,
/// a one-byte flag field, and an optional payload. Metadata messages serialize
/// [`RpcMetadata`] to JSON while data messages carry gRPC-framed payloads.
abstract class RpcTurnRelayTransportBase implements IRpcTransport {
  RpcTurnRelayTransportBase({
    required TurnRelayClient client,
    required this.peerAddress,
    required this.peerPort,
    required RpcStreamIdManager idManager,
    bool manageClientLifecycle = false,
    RpcLogger? logger,
  })  : _client = client,
        _idManager = idManager,
        _manageClientLifecycle = manageClientLifecycle,
        _logger = logger?.child('RpcTurnRelayTransport'),
        _incomingController =
            StreamController<RpcTransportMessage>.broadcast() {
    _subscription = _client.bytes.listen(
      _handleIncomingBytes,
      onError: _handleError,
      onDone: _handleDone,
    );
  }

  /// Peer address used for outbound relay traffic.
  final InternetAddress peerAddress;

  /// Peer port used for outbound relay traffic.
  final int peerPort;

  final TurnRelayClient _client;
  final RpcStreamIdManager _idManager;
  final bool _manageClientLifecycle;
  final RpcLogger? _logger;
  final StreamController<RpcTransportMessage> _incomingController;

  StreamSubscription<Uint8List>? _subscription;
  final Map<int, RpcMessageParser> _streamParsers = {};
  bool _closed = false;

  @override
  bool get isClosed => _closed || _client.isClosed;

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  int createStream() {
    if (_closed) {
      throw StateError('TURN relay transport is closed');
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

    if (_manageClientLifecycle && !_client.isClosed) {
      await _client.close();
    }

    if (!_incomingController.isClosed) {
      await _incomingController.close();
    }
  }

  @override
  Future<RpcHealthStatus> health() async {
    if (_incomingController.isClosed) {
      return RpcHealthStatus.closed(
        component: runtimeType.toString(),
        message: 'TURN relay transport closed',
      );
    }

    if (_closed || _client.isClosed) {
      return RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'TURN relay client connection is closed',
      );
    }

    return RpcHealthStatus.healthy(
      component: runtimeType.toString(),
      message: 'TURN relay transport ready',
    );
  }

  @override
  Future<RpcHealthStatus> reconnect() async {
    return RpcHealthStatus.degraded(
      component: runtimeType.toString(),
      message: 'Reconnect is not supported for TURN relay transports',
      details: const {'supported': false},
    );
  }

  @override
  bool get supportsZeroCopy => false;

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

    await _client.send(
      packet,
      peerAddress: peerAddress,
      peerPort: peerPort,
    );
  }

  void _handleIncomingBytes(Uint8List message) {
    if (_closed) {
      return;
    }

    if (message.length < 5) {
      _logger?.warning('Ignoring short TURN relay frame of ${message.length} bytes');
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
      'TURN relay client error: $error',
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _handleDone() {
    _logger?.info('TURN relay client closed');
    _closed = true;

    if (!_incomingController.isClosed) {
      _incomingController.close();
    }
  }
}

/// Client-side transport that uses odd stream identifiers.
final class RpcTurnRelayCallerTransport extends RpcTurnRelayTransportBase {
  RpcTurnRelayCallerTransport._({
    required super.client,
    required super.peerAddress,
    required super.peerPort,
    required RpcStreamIdManager idManager,
    super.manageClientLifecycle,
    super.logger,
  }) : super(idManager: idManager);

  factory RpcTurnRelayCallerTransport.fromClient({
    required TurnRelayClient client,
    required InternetAddress peerAddress,
    required int peerPort,
    bool manageClientLifecycle = false,
    RpcLogger? logger,
  }) {
    return RpcTurnRelayCallerTransport._(
      client: client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      idManager: RpcStreamIdManager(isClient: true),
      manageClientLifecycle: manageClientLifecycle,
      logger: logger,
    );
  }

  static Future<RpcTurnRelayCallerTransport> connect({
    required InternetAddress serverAddress,
    required int serverPort,
    required InternetAddress peerAddress,
    required int peerPort,
    InternetAddress? localAddress,
    int localPort = 0,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration? requestedAllocationLifetime,
    Duration allocationRefreshMargin = const Duration(seconds: 30),
    Duration permissionLifetime = const Duration(minutes: 5),
    Duration permissionRefreshMargin = const Duration(seconds: 30),
    bool autoCreatePermission = true,
    RpcLogger? logger,
  }) async {
    final client = await TurnRelayClient.connect(
      serverAddress: serverAddress,
      serverPort: serverPort,
      localAddress: localAddress,
      localPort: localPort,
      requestTimeout: requestTimeout,
      requestedAllocationLifetime: requestedAllocationLifetime,
      allocationRefreshMargin: allocationRefreshMargin,
      permissionLifetime: permissionLifetime,
      permissionRefreshMargin: permissionRefreshMargin,
      autoCreatePermission: autoCreatePermission,
    );

    return RpcTurnRelayCallerTransport._(
      client: client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      idManager: RpcStreamIdManager(isClient: true),
      manageClientLifecycle: true,
      logger: logger,
    );
  }

  @override
  bool get isClient => true;
}

/// Server-side transport that uses even stream identifiers.
final class RpcTurnRelayResponderTransport extends RpcTurnRelayTransportBase {
  RpcTurnRelayResponderTransport._({
    required super.client,
    required super.peerAddress,
    required super.peerPort,
    required RpcStreamIdManager idManager,
    super.manageClientLifecycle,
    super.logger,
  }) : super(idManager: idManager);

  factory RpcTurnRelayResponderTransport.fromClient({
    required TurnRelayClient client,
    required InternetAddress peerAddress,
    required int peerPort,
    bool manageClientLifecycle = false,
    RpcLogger? logger,
  }) {
    return RpcTurnRelayResponderTransport._(
      client: client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      idManager: RpcStreamIdManager(isClient: false),
      manageClientLifecycle: manageClientLifecycle,
      logger: logger,
    );
  }

  static Future<RpcTurnRelayResponderTransport> connect({
    required InternetAddress serverAddress,
    required int serverPort,
    required InternetAddress peerAddress,
    required int peerPort,
    InternetAddress? localAddress,
    int localPort = 0,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration? requestedAllocationLifetime,
    Duration allocationRefreshMargin = const Duration(seconds: 30),
    Duration permissionLifetime = const Duration(minutes: 5),
    Duration permissionRefreshMargin = const Duration(seconds: 30),
    bool autoCreatePermission = true,
    RpcLogger? logger,
  }) async {
    final client = await TurnRelayClient.connect(
      serverAddress: serverAddress,
      serverPort: serverPort,
      localAddress: localAddress,
      localPort: localPort,
      requestTimeout: requestTimeout,
      requestedAllocationLifetime: requestedAllocationLifetime,
      allocationRefreshMargin: allocationRefreshMargin,
      permissionLifetime: permissionLifetime,
      permissionRefreshMargin: permissionRefreshMargin,
      autoCreatePermission: autoCreatePermission,
    );

    return RpcTurnRelayResponderTransport._(
      client: client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      idManager: RpcStreamIdManager(isClient: false),
      manageClientLifecycle: true,
      logger: logger,
    );
  }

  @override
  bool get isClient => false;
}
