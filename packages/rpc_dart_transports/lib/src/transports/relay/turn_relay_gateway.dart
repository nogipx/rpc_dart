// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart' as io;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket gateway that hosts TURN allocations on the server side and exposes
/// them to browser clients through RPC.
class TurnRelayGatewayServer {
  TurnRelayGatewayServer({
    required io.InternetAddress bindAddress,
    required int bindPort,
    required this.relayAddress,
    required this.relayPort,
    this.clientOptions = const TurnRelayClientOptions(),
    this.logger,
  })  : _bindAddress = bindAddress,
        _bindPort = bindPort;

  final io.InternetAddress _bindAddress;
  final int _bindPort;

  /// TURN relay address used by every gateway session.
  final io.InternetAddress relayAddress;

  /// TURN relay port used by every gateway session.
  final int relayPort;

  /// Options applied when creating [TurnRelayClient] instances.
  final TurnRelayClientOptions clientOptions;

  /// Optional logger for gateway level messages.
  final RpcLogger? logger;

  io.HttpServer? _httpServer;
  final Set<_GatewayConnection> _connections = <_GatewayConnection>{};
  bool _starting = false;

  /// Whether the gateway is currently running.
  bool get isRunning => _httpServer != null;

  /// Actual port used by the HTTP/WebSocket server.
  int get port => _httpServer?.port ?? _bindPort;

  io.InternetAddress get bindAddress => _bindAddress;

  /// Starts the HTTP listener and begins accepting WebSocket clients.
  Future<void> start() async {
    if (isRunning || _starting) {
      return;
    }
    _starting = true;

    try {
      _httpServer = await io.HttpServer.bind(_bindAddress, _bindPort);
      logger?.info(
        'TURN relay gateway listening on ws://${_bindAddress.address}:${_httpServer!.port}',
      );

      _httpServer!.listen(
        (io.HttpRequest request) {
          if (!io.WebSocketTransformer.isUpgradeRequest(request)) {
            request.response
              ..statusCode = io.HttpStatus.notFound
              ..write('Not Found')
              ..close();
            return;
          }

          _handleUpgrade(request);
        },
        onError: (Object error, StackTrace stackTrace) {
          logger?.error('Gateway HTTP server error', error: error, stackTrace: stackTrace);
        },
        cancelOnError: false,
      );
    } finally {
      _starting = false;
    }
  }

  /// Stops the gateway and disposes all active sessions.
  Future<void> stop() async {
    final server = _httpServer;
    if (server == null) {
      return;
    }

    logger?.info('Stopping TURN relay gateway');
    _httpServer = null;

    await Future.wait(_connections.map((connection) => connection.close()));
    _connections.clear();

    await server.close(force: true);
  }

  Future<void> _handleUpgrade(io.HttpRequest request) async {
    io.WebSocket? socket;
    try {
      socket = await io.WebSocketTransformer.upgrade(request);
    } catch (error, stackTrace) {
      logger?.error('Failed to upgrade to WebSocket', error: error, stackTrace: stackTrace);
      return;
    }

    TurnRelayClient client;
    try {
      client = await TurnRelayClient.connect(
        serverAddress: relayAddress,
        serverPort: relayPort,
        options: clientOptions,
      );
    } catch (error, stackTrace) {
      logger?.error('Failed to connect to TURN relay', error: error, stackTrace: stackTrace);
      await socket.close(io.WebSocketStatus.internalServerError);
      return;
    }

    final channel = IOWebSocketChannel(socket);
    final transport = RpcWebSocketResponderTransport(channel, logger: logger);
    final endpoint = RpcResponderEndpoint(
      transport: transport,
      debugLabel: 'turn-gateway',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
    );

    final session = TurnRelayGatewaySession(client: client, logger: logger);
    final responder = TurnRelayGatewayResponder(session, logger: logger);
    endpoint.registerServiceContract(responder);
    endpoint.start();

    final connection = _GatewayConnection(
      endpoint: endpoint,
      session: session,
      channel: channel,
      logger: logger,
    );

    _connections.add(connection);

    channel.sink.done.then((_) async {
      await connection.close();
      _connections.remove(connection);
    }).ignore();
  }
}

class _GatewayConnection {
  _GatewayConnection({
    required this.endpoint,
    required this.session,
    required this.channel,
    this.logger,
  });

  final RpcResponderEndpoint endpoint;
  final TurnRelayGatewaySession session;
  final WebSocketChannel channel;
  final RpcLogger? logger;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    logger?.debug('Closing TURN gateway connection');
    await Future.wait([
      endpoint.close(),
      session.close(),
      channel.sink.close(),
    ]);
  }
}

/// Per-connection session that wraps a [TurnRelayClient] and exposes helper
/// operations for RPC contracts.
class TurnRelayGatewaySession {
  TurnRelayGatewaySession({
    required this.client,
    this.logger,
  });

  final TurnRelayClient client;
  final RpcLogger? logger;

  TurnRelayGatewayAllocationInfo get allocationInfo =>
      TurnRelayGatewayAllocationInfo(
        relayAddress: client.relayAddress.address,
        relayPort: client.relayPort,
      );

  Stream<TurnRelayGatewayConnectNotification> connectRequests() {
    return client.connectRequests.map(
      (TurnConnectRequest request) => TurnRelayGatewayConnectNotification(
        peerAddress: request.peerAddress.address,
        peerPort: request.peerPort,
        payload: request.payload != null
            ? Uint8List.fromList(request.payload!)
            : null,
      ),
    );
  }

  Stream<TurnRelayGatewayBinaryFrame> incomingBytes() {
    return client.bytes.map(
      (Uint8List data) => TurnRelayGatewayBinaryFrame(
        data: Uint8List.fromList(data),
      ),
    );
  }

  Future<void> sendToPeer({
    required String peerAddress,
    required int peerPort,
    required Uint8List payload,
  }) async {
    final address = _parseAddress(peerAddress);
    if (address == null) {
      throw ArgumentError.value(peerAddress, 'peerAddress', 'Invalid IPv4 address');
    }

    await client.send(
      Uint8List.fromList(payload),
      peerAddress: address,
      peerPort: peerPort,
    );
  }

  Future<void> requestPeerConnection({
    required String peerAddress,
    required int peerPort,
    Uint8List? payload,
  }) async {
    final address = _parseAddress(peerAddress);
    if (address == null) {
      throw ArgumentError.value(peerAddress, 'peerAddress', 'Invalid IPv4 address');
    }

    await client.requestPeerConnection(
      peerAddress: address,
      peerPort: peerPort,
      payload: payload != null ? Uint8List.fromList(payload) : null,
    );
  }

  Future<void> close() async {
    await client.close();
  }

  io.InternetAddress? _parseAddress(String value) {
    final address = io.InternetAddress.tryParse(value);
    if (address != null) {
      return address;
    }

    final segments = value.split('.');
    if (segments.length != 4) {
      return null;
    }

    final bytes = Uint8List(4);
    for (var i = 0; i < segments.length; i++) {
      final segment = int.tryParse(segments[i]);
      if (segment == null || segment < 0 || segment > 255) {
        return null;
      }
      bytes[i] = segment;
    }

    return io.InternetAddress.fromRawAddress(bytes);
  }
}

/// RPC responder contract bound to a [TurnRelayGatewaySession].
class TurnRelayGatewayResponder extends RpcResponderContract {
  TurnRelayGatewayResponder(this._session, {RpcLogger? logger})
      : _logger = logger?.child('TurnRelayGatewayResponder'),
        super('turnRelayGateway', dataTransferMode: RpcDataTransferMode.codec) {
    _registerMethods();
  }

  final TurnRelayGatewaySession _session;
  final RpcLogger? _logger;

  void _registerMethods() {
    addUnaryMethod<RpcNull, TurnRelayGatewayAllocationInfo>(
      methodName: 'GetAllocationInfo',
      requestCodec: RpcNull.codec,
      responseCodec: TurnRelayGatewayAllocationInfo.codec,
      handler: (request, {context}) async {
        _logger?.debug('Allocation info requested');
        return _session.allocationInfo;
      },
    );

    addUnaryMethod<TurnRelayGatewayPeerRequest, RpcNull>(
      methodName: 'RequestPeerConnection',
      requestCodec: TurnRelayGatewayPeerRequest.codec,
      responseCodec: RpcNull.codec,
      handler: (request, {context}) async {
        _logger?.debug(
          'Requesting peer connection to ${request.peerAddress}:${request.peerPort}',
        );
        await _session.requestPeerConnection(
          peerAddress: request.peerAddress,
          peerPort: request.peerPort,
          payload: request.payload,
        );
        return const RpcNull();
      },
    );

    addUnaryMethod<TurnRelayGatewaySendRequest, RpcNull>(
      methodName: 'SendToPeer',
      requestCodec: TurnRelayGatewaySendRequest.codec,
      responseCodec: RpcNull.codec,
      handler: (request, {context}) async {
        _logger?.debug(
          'Sending ${request.payload.length} bytes to ${request.peerAddress}:${request.peerPort}',
        );
        await _session.sendToPeer(
          peerAddress: request.peerAddress,
          peerPort: request.peerPort,
          payload: request.payload,
        );
        return const RpcNull();
      },
    );

    addServerStreamMethod<RpcNull, TurnRelayGatewayConnectNotification>(
      methodName: 'WatchConnectRequests',
      requestCodec: RpcNull.codec,
      responseCodec: TurnRelayGatewayConnectNotification.codec,
      handler: (request, {context}) {
        _logger?.debug('Subscribing to connect requests');
        return _session.connectRequests();
      },
    );

    addServerStreamMethod<RpcNull, TurnRelayGatewayBinaryFrame>(
      methodName: 'WatchIncomingBytes',
      requestCodec: RpcNull.codec,
      responseCodec: TurnRelayGatewayBinaryFrame.codec,
      handler: (request, {context}) {
        _logger?.debug('Subscribing to inbound payloads');
        return _session.incomingBytes();
      },
    );
  }

  @override
  void dispose() {
    unawaited(_session.close());
    super.dispose();
  }
}

/// Client-side helper contract for accessing gateway RPC methods.
class TurnRelayGatewayCaller extends RpcCallerContract {
  TurnRelayGatewayCaller(RpcCallerEndpoint endpoint)
      : super('turnRelayGateway', endpoint, dataTransferMode: RpcDataTransferMode.codec);

  Future<TurnRelayGatewayAllocationInfo> getAllocationInfo() {
    return endpoint.unaryRequest<RpcNull, TurnRelayGatewayAllocationInfo>(
      serviceName: serviceName,
      methodName: 'GetAllocationInfo',
      requestCodec: RpcNull.codec,
      responseCodec: TurnRelayGatewayAllocationInfo.codec,
      request: const RpcNull(),
    );
  }

  Future<void> requestPeerConnection(TurnRelayGatewayPeerRequest request) async {
    await endpoint.unaryRequest<TurnRelayGatewayPeerRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'RequestPeerConnection',
      requestCodec: TurnRelayGatewayPeerRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  Future<void> sendToPeer(TurnRelayGatewaySendRequest request) async {
    await endpoint.unaryRequest<TurnRelayGatewaySendRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'SendToPeer',
      requestCodec: TurnRelayGatewaySendRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  Stream<TurnRelayGatewayConnectNotification> watchConnectRequests() {
    return endpoint
        .serverStream<RpcNull, TurnRelayGatewayConnectNotification>(
          serviceName: serviceName,
          methodName: 'WatchConnectRequests',
          requestCodec: RpcNull.codec,
          responseCodec: TurnRelayGatewayConnectNotification.codec,
          request: const RpcNull(),
        )
        .asBroadcastStream();
  }

  Stream<Uint8List> watchIncomingBytes() {
    return endpoint
        .serverStream<RpcNull, TurnRelayGatewayBinaryFrame>(
          serviceName: serviceName,
          methodName: 'WatchIncomingBytes',
          requestCodec: RpcNull.codec,
          responseCodec: TurnRelayGatewayBinaryFrame.codec,
          request: const RpcNull(),
        )
        .map((TurnRelayGatewayBinaryFrame frame) => Uint8List.fromList(frame.data))
        .asBroadcastStream();
  }
}

class TurnRelayGatewayAllocationInfo implements IRpcSerializable {
  TurnRelayGatewayAllocationInfo({
    required this.relayAddress,
    required this.relayPort,
  });

  final String relayAddress;
  final int relayPort;

  Map<String, dynamic> toJson() => {
        'relayAddress': relayAddress,
        'relayPort': relayPort,
      };

  factory TurnRelayGatewayAllocationInfo.fromJson(Map<String, dynamic> json) {
    final address = json['relayAddress'] as String?;
    final port = (json['relayPort'] as num?)?.toInt();
    if (address == null || address.isEmpty || port == null) {
      throw const FormatException('Invalid allocation info payload');
    }
    return TurnRelayGatewayAllocationInfo(
      relayAddress: address,
      relayPort: port,
    );
  }

  static const RpcCodec<TurnRelayGatewayAllocationInfo> codec =
      RpcCodec<TurnRelayGatewayAllocationInfo>.withDecoder(
    TurnRelayGatewayAllocationInfo.fromJson,
  );
}

class TurnRelayGatewayConnectNotification implements IRpcSerializable {
  TurnRelayGatewayConnectNotification({
    required this.peerAddress,
    required this.peerPort,
    this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List? payload;

  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        if (payload != null) 'payload': base64Encode(payload!),
      };

  factory TurnRelayGatewayConnectNotification.fromJson(Map<String, dynamic> json) {
    final address = json['peerAddress'] as String?;
    final port = (json['peerPort'] as num?)?.toInt();
    if (address == null || address.isEmpty || port == null) {
      throw const FormatException('Invalid connect notification payload');
    }

    final payloadRaw = json['payload'] as String?;
    return TurnRelayGatewayConnectNotification(
      peerAddress: address,
      peerPort: port,
      payload: payloadRaw != null ? base64Decode(payloadRaw) : null,
    );
  }

  static const RpcCodec<TurnRelayGatewayConnectNotification> codec =
      RpcCodec<TurnRelayGatewayConnectNotification>.withDecoder(
    TurnRelayGatewayConnectNotification.fromJson,
  );
}

class TurnRelayGatewayPeerRequest implements IRpcSerializable {
  TurnRelayGatewayPeerRequest({
    required this.peerAddress,
    required this.peerPort,
    this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List? payload;

  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        if (payload != null) 'payload': base64Encode(payload!),
      };

  factory TurnRelayGatewayPeerRequest.fromJson(Map<String, dynamic> json) {
    final address = json['peerAddress'] as String?;
    final port = (json['peerPort'] as num?)?.toInt();
    if (address == null || address.isEmpty || port == null) {
      throw const FormatException('Invalid peer request payload');
    }

    final payloadRaw = json['payload'] as String?;
    return TurnRelayGatewayPeerRequest(
      peerAddress: address,
      peerPort: port,
      payload: payloadRaw != null ? base64Decode(payloadRaw) : null,
    );
  }

  static const RpcCodec<TurnRelayGatewayPeerRequest> codec =
      RpcCodec<TurnRelayGatewayPeerRequest>.withDecoder(
    TurnRelayGatewayPeerRequest.fromJson,
  );
}

class TurnRelayGatewaySendRequest implements IRpcSerializable {
  TurnRelayGatewaySendRequest({
    required this.peerAddress,
    required this.peerPort,
    required this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List payload;

  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        'payload': base64Encode(payload),
      };

  factory TurnRelayGatewaySendRequest.fromJson(Map<String, dynamic> json) {
    final address = json['peerAddress'] as String?;
    final port = (json['peerPort'] as num?)?.toInt();
    final payloadRaw = json['payload'] as String?;
    if (address == null || address.isEmpty || port == null || payloadRaw == null) {
      throw const FormatException('Invalid send request payload');
    }

    return TurnRelayGatewaySendRequest(
      peerAddress: address,
      peerPort: port,
      payload: base64Decode(payloadRaw),
    );
  }

  static const RpcCodec<TurnRelayGatewaySendRequest> codec =
      RpcCodec<TurnRelayGatewaySendRequest>.withDecoder(
    TurnRelayGatewaySendRequest.fromJson,
  );
}

class TurnRelayGatewayBinaryFrame implements IRpcSerializable {
  TurnRelayGatewayBinaryFrame({required this.data});

  final Uint8List data;

  Map<String, dynamic> toJson() => {
        'data': base64Encode(data),
      };

  factory TurnRelayGatewayBinaryFrame.fromJson(Map<String, dynamic> json) {
    final payloadRaw = json['data'] as String?;
    if (payloadRaw == null) {
      throw const FormatException('Missing binary frame payload');
    }
    return TurnRelayGatewayBinaryFrame(data: base64Decode(payloadRaw));
  }

  static const RpcCodec<TurnRelayGatewayBinaryFrame> codec =
      RpcCodec<TurnRelayGatewayBinaryFrame>.withDecoder(
    TurnRelayGatewayBinaryFrame.fromJson,
  );
}

extension on Future<void> {
  void ignore() {
    unawaited(this);
  }
}
