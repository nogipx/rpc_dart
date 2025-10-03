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

import 'turn_relay_stream_transport_core.dart';

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
/// Maintains a single TURN allocation on behalf of a WebSocket client.
///
/// The session adapts the binary [TurnRelayClient] API to JSON-friendly RPC
/// payloads consumed by browser transports. Incoming TURN events are converted
/// to DTOs while outbound RPC requests are validated before reaching the
/// underlying client.
class TurnRelayGatewaySession {
  TurnRelayGatewaySession({
    required this.client,
    this.logger,
  });

  final TurnRelayClient client;
  final RpcLogger? logger;

  /// Returns metadata describing the active relay allocation for the session.
  TurnRelayGatewayAllocationInfo get allocationInfo =>
      TurnRelayGatewayAllocationInfo(
        relayAddress: client.relayAddress.address,
        relayPort: client.relayPort,
      );

  /// Emits an RPC-friendly stream of TURN Connect requests originating from
  /// remote peers.
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

  /// Converts inbound TURN payloads to binary frames suitable for RPC
  /// transport.
  Stream<TurnRelayGatewayBinaryFrame> incomingBytes() {
    return client.bytes.map(
      (Uint8List data) => TurnRelayGatewayBinaryFrame(
        data: Uint8List.fromList(data),
      ),
    );
  }

  /// Sends [payload] to a peer through the relay after validating the target
  /// address string.
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

  /// Requests that the relay signals [peerAddress]:[peerPort] about the
  /// client's intent to communicate and optionally forwards an application
  /// payload.
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

  /// Registers the allocation in the discovery catalogue maintained by the
  /// relay.
  Future<void> registerService({
    required String serviceId,
    String? description,
  }) {
    return client.registerService(serviceId: serviceId, description: description);
  }

  /// Lists discovery entries and converts them to gateway DTOs.
  Future<List<TurnRelayGatewayServiceInfo>> listServices({String? serviceId}) async {
    final services = await client.listServices(serviceId: serviceId);
    return services
        .map(
          (service) => TurnRelayGatewayServiceInfo(
            serviceId: service.serviceId,
            relayAddress: service.relayAddress.address,
            relayPort: service.relayPort,
            description: service.description,
            clientAddress: service.clientAddress?.address,
            clientPort: service.clientPort,
            updatedAt: service.updatedAt?.toIso8601String(),
          ),
        )
        .toList(growable: false);
  }

  /// Adds or refreshes a permission for the provided peer endpoint.
  Future<void> addPermission({
    required String peerAddress,
    required int peerPort,
  }) async {
    final address = _parseAddress(peerAddress);
    if (address == null) {
      throw ArgumentError.value(peerAddress, 'peerAddress', 'Invalid IPv4 address');
    }

    await client.addPermission(address, peerPort);
  }

  /// Releases the underlying relay client and associated resources.
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
///
/// The responder exposes gateway capabilities to callers by registering unary
/// and streaming RPC methods that mirror the native TURN client surface.
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

    addUnaryMethod<TurnRelayGatewayRegisterServiceRequest, RpcNull>(
      methodName: 'RegisterService',
      requestCodec: TurnRelayGatewayRegisterServiceRequest.codec,
      responseCodec: RpcNull.codec,
      handler: (request, {context}) async {
        _logger?.debug('Registering service ${request.serviceId}');
        await _session.registerService(
          serviceId: request.serviceId,
          description: request.description,
        );
        return const RpcNull();
      },
    );

    addUnaryMethod<TurnRelayGatewayListServicesRequest,
        RpcList<TurnRelayGatewayServiceInfo>>(
      methodName: 'ListServices',
      requestCodec: TurnRelayGatewayListServicesRequest.codec,
      responseCodec: _gatewayServiceListCodec,
      handler: (request, {context}) async {
        _logger?.debug('Listing services for ${request.serviceId ?? '*'}');
        final services = await _session.listServices(serviceId: request.serviceId);
        return RpcList<TurnRelayGatewayServiceInfo>.from(services);
      },
    );

    addUnaryMethod<TurnRelayGatewayPermissionRequest, RpcNull>(
      methodName: 'AddPermission',
      requestCodec: TurnRelayGatewayPermissionRequest.codec,
      responseCodec: RpcNull.codec,
      handler: (request, {context}) async {
        _logger?.debug(
          'Creating permission for ${request.peerAddress}:${request.peerPort}',
        );
        await _session.addPermission(
          peerAddress: request.peerAddress,
          peerPort: request.peerPort,
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
///
/// The caller mirrors the [TurnRelayClient] API surface while delegating all
/// transport to the provided [RpcCallerEndpoint], making it suitable for
/// runtimes without direct socket support such as Flutter Web.
class TurnRelayGatewayCaller extends RpcCallerContract {
  TurnRelayGatewayCaller(RpcCallerEndpoint endpoint)
      : super('turnRelayGateway', endpoint, dataTransferMode: RpcDataTransferMode.codec);

  /// Retrieves the relay allocation endpoint owned by the active session.
  Future<TurnRelayGatewayAllocationInfo> getAllocationInfo() {
    return endpoint.unaryRequest<RpcNull, TurnRelayGatewayAllocationInfo>(
      serviceName: serviceName,
      methodName: 'GetAllocationInfo',
      requestCodec: RpcNull.codec,
      responseCodec: TurnRelayGatewayAllocationInfo.codec,
      request: const RpcNull(),
    );
  }

  /// Asks the relay to notify a peer about the caller's desire to connect and
  /// optionally forwards a payload.
  Future<void> requestPeerConnection(TurnRelayGatewayPeerRequest request) async {
    await endpoint.unaryRequest<TurnRelayGatewayPeerRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'RequestPeerConnection',
      requestCodec: TurnRelayGatewayPeerRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  /// Sends arbitrary data to a peer via the relay allocation.
  Future<void> sendToPeer(TurnRelayGatewaySendRequest request) async {
    await endpoint.unaryRequest<TurnRelayGatewaySendRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'SendToPeer',
      requestCodec: TurnRelayGatewaySendRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  /// Registers the allocation in the relay discovery catalogue.
  Future<void> registerService(
    TurnRelayGatewayRegisterServiceRequest request,
  ) async {
    await endpoint.unaryRequest<TurnRelayGatewayRegisterServiceRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'RegisterService',
      requestCodec: TurnRelayGatewayRegisterServiceRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  /// Lists discovery entries currently advertised by the relay gateway.
  Future<List<TurnRelayGatewayServiceInfo>> listServices({String? serviceId}) async {
    final response =
        await endpoint.unaryRequest<TurnRelayGatewayListServicesRequest,
            RpcList<TurnRelayGatewayServiceInfo>>(
      serviceName: serviceName,
      methodName: 'ListServices',
      requestCodec: TurnRelayGatewayListServicesRequest.codec,
      responseCodec: _gatewayServiceListCodec,
      request: TurnRelayGatewayListServicesRequest(serviceId: serviceId),
    );

    return response.toList();
  }

  /// Creates or refreshes a permission for a peer reachable through the relay.
  Future<void> addPermission(TurnRelayGatewayPermissionRequest request) async {
    await endpoint.unaryRequest<TurnRelayGatewayPermissionRequest, RpcNull>(
      serviceName: serviceName,
      methodName: 'AddPermission',
      requestCodec: TurnRelayGatewayPermissionRequest.codec,
      responseCodec: RpcNull.codec,
      request: request,
    );
  }

  /// Subscribes to TURN Connect indications emitted for the caller's
  /// allocation.
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

  /// Subscribes to raw payloads delivered to the caller's allocation.
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

/// Shared base for gateway-backed transports that operate on top of the
/// [`TurnRelayGatewayCaller`] RPC surface.
abstract class RpcTurnRelayGatewayTransportBase
    extends RpcTurnRelayStreamTransportCore {
  RpcTurnRelayGatewayTransportBase({
    required this.gateway,
    required this.peerAddress,
    required this.peerPort,
    required bool isClient,
    bool manageGatewayLifecycle = false,
    RpcLogger? logger,
  }) : super(
          componentName: 'RpcTurnRelayGatewayTransport',
          idManager: RpcStreamIdManager(isClient: isClient),
          incomingDatagrams: gateway.watchIncomingBytes(),
          sendDatagram: (packet) => gateway.sendToPeer(
            TurnRelayGatewaySendRequest(
              peerAddress: peerAddress,
              peerPort: peerPort,
              payload: packet,
            ),
          ),
          onClose: manageGatewayLifecycle ? gateway.endpoint.close : null,
          customReconnect: () async => RpcHealthStatus.degraded(
            component: 'RpcTurnRelayGatewayTransport',
            message: 'Reconnect is not supported for gateway transports',
            details: const {'supported': false},
          ),
          logger: logger?.child('RpcTurnRelayGatewayTransport'),
        );

  /// RPC helper that bridges the browser client with the TURN allocation.
  final TurnRelayGatewayCaller gateway;

  /// Target peer relay address used when sending packets.
  final String peerAddress;

  /// Target peer relay port used when sending packets.
  final int peerPort;
}

/// Client-side transport that multiplexes RPC calls over the gateway session.
final class RpcTurnRelayGatewayCallerTransport
    extends RpcTurnRelayGatewayTransportBase {
  RpcTurnRelayGatewayCallerTransport({
    required TurnRelayGatewayCaller gateway,
    required String peerAddress,
    required int peerPort,
    bool manageGatewayLifecycle = false,
    RpcLogger? logger,
  }) : super(
          gateway: gateway,
          peerAddress: peerAddress,
          peerPort: peerPort,
          isClient: true,
          manageGatewayLifecycle: manageGatewayLifecycle,
          logger: logger,
        );

  @override
  bool get isClient => true;
}

/// Server-side transport that allows gateway clients to host RPC responders.
final class RpcTurnRelayGatewayResponderTransport
    extends RpcTurnRelayGatewayTransportBase {
  RpcTurnRelayGatewayResponderTransport({
    required TurnRelayGatewayCaller gateway,
    required String peerAddress,
    required int peerPort,
    bool manageGatewayLifecycle = false,
    RpcLogger? logger,
  }) : super(
          gateway: gateway,
          peerAddress: peerAddress,
          peerPort: peerPort,
          isClient: false,
          manageGatewayLifecycle: manageGatewayLifecycle,
          logger: logger,
        );

  @override
  bool get isClient => false;
}

/// JSON-serializable description of a TURN allocation hosted by the gateway.
class TurnRelayGatewayAllocationInfo implements IRpcSerializable {
  TurnRelayGatewayAllocationInfo({
    required this.relayAddress,
    required this.relayPort,
  });

  final String relayAddress;
  final int relayPort;

  /// Serializes the allocation info into JSON.
  Map<String, dynamic> toJson() => {
        'relayAddress': relayAddress,
        'relayPort': relayPort,
      };

  /// Deserializes the allocation info from JSON.
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

/// Notification produced when the relay forwards a Connect indication to the
/// gateway client.
class TurnRelayGatewayConnectNotification implements IRpcSerializable {
  TurnRelayGatewayConnectNotification({
    required this.peerAddress,
    required this.peerPort,
    this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List? payload;

  /// Serializes the notification into JSON, encoding [payload] with base64.
  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        if (payload != null) 'payload': base64Encode(payload!),
      };

  /// Deserializes the notification from JSON.
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

/// RPC request asking the gateway to initiate a peer connection through TURN.
class TurnRelayGatewayPeerRequest implements IRpcSerializable {
  TurnRelayGatewayPeerRequest({
    required this.peerAddress,
    required this.peerPort,
    this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List? payload;

  /// Serializes the peer request into JSON.
  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        if (payload != null) 'payload': base64Encode(payload!),
      };

  /// Deserializes the peer request from JSON.
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

/// RPC request registering the current allocation in the discovery catalogue.
class TurnRelayGatewayRegisterServiceRequest implements IRpcSerializable {
  TurnRelayGatewayRegisterServiceRequest({
    required this.serviceId,
    this.description,
  });

  final String serviceId;
  final String? description;

  /// Serializes the registration request into JSON.
  Map<String, dynamic> toJson() => {
        'serviceId': serviceId,
        if (description != null) 'description': description,
      };

  /// Deserializes the registration request from JSON.
  factory TurnRelayGatewayRegisterServiceRequest.fromJson(
    Map<String, dynamic> json,
  ) {
    final serviceId = json['serviceId'] as String?;
    if (serviceId == null || serviceId.isEmpty) {
      throw const FormatException('Invalid register service payload');
    }

    return TurnRelayGatewayRegisterServiceRequest(
      serviceId: serviceId,
      description: json['description'] as String?,
    );
  }

  static const RpcCodec<TurnRelayGatewayRegisterServiceRequest> codec =
      RpcCodec<TurnRelayGatewayRegisterServiceRequest>.withDecoder(
    TurnRelayGatewayRegisterServiceRequest.fromJson,
  );
}

/// RPC request used to list relay discovery entries.
class TurnRelayGatewayListServicesRequest implements IRpcSerializable {
  TurnRelayGatewayListServicesRequest({this.serviceId});

  final String? serviceId;

  /// Serializes the listing request into JSON.
  Map<String, dynamic> toJson() => {
        if (serviceId != null) 'serviceId': serviceId,
      };

  /// Deserializes the listing request from JSON.
  factory TurnRelayGatewayListServicesRequest.fromJson(
    Map<String, dynamic> json,
  ) {
    return TurnRelayGatewayListServicesRequest(
      serviceId: json['serviceId'] as String?,
    );
  }

  static const RpcCodec<TurnRelayGatewayListServicesRequest> codec =
      RpcCodec<TurnRelayGatewayListServicesRequest>.withDecoder(
    TurnRelayGatewayListServicesRequest.fromJson,
  );
}

/// RPC request instructing the gateway to create or refresh a permission.
class TurnRelayGatewayPermissionRequest implements IRpcSerializable {
  TurnRelayGatewayPermissionRequest({
    required this.peerAddress,
    required this.peerPort,
  });

  final String peerAddress;
  final int peerPort;

  /// Serializes the permission request into JSON.
  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
      };

  /// Deserializes a permission request from JSON.
  factory TurnRelayGatewayPermissionRequest.fromJson(Map<String, dynamic> json) {
    final peerAddress = json['peerAddress'] as String?;
    final peerPort = (json['peerPort'] as num?)?.toInt();
    if (peerAddress == null || peerAddress.isEmpty || peerPort == null) {
      throw const FormatException('Invalid permission request payload');
    }

    return TurnRelayGatewayPermissionRequest(
      peerAddress: peerAddress,
      peerPort: peerPort,
    );
  }

  static const RpcCodec<TurnRelayGatewayPermissionRequest> codec =
      RpcCodec<TurnRelayGatewayPermissionRequest>.withDecoder(
    TurnRelayGatewayPermissionRequest.fromJson,
  );
}

/// Discovery catalogue entry returned to RPC callers.
class TurnRelayGatewayServiceInfo implements IRpcSerializable {
  TurnRelayGatewayServiceInfo({
    required this.serviceId,
    required this.relayAddress,
    required this.relayPort,
    this.description,
    this.clientAddress,
    this.clientPort,
    this.updatedAt,
  });

  final String serviceId;
  final String relayAddress;
  final int relayPort;
  final String? description;
  final String? clientAddress;
  final int? clientPort;
  final String? updatedAt;

  /// Converts the service info into a JSON map.
  Map<String, dynamic> toJson() => {
        'serviceId': serviceId,
        'relayAddress': relayAddress,
        'relayPort': relayPort,
        if (description != null) 'description': description,
        if (clientAddress != null) 'clientAddress': clientAddress,
        if (clientPort != null) 'clientPort': clientPort,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };

  /// Deserializes a discovery entry from JSON.
  factory TurnRelayGatewayServiceInfo.fromJson(Map<String, dynamic> json) {
    final serviceId = json['serviceId'] as String?;
    final relayAddress = json['relayAddress'] as String?;
    final relayPort = (json['relayPort'] as num?)?.toInt();
    if (serviceId == null || serviceId.isEmpty) {
      throw const FormatException('Invalid service info: missing serviceId');
    }
    if (relayAddress == null || relayAddress.isEmpty || relayPort == null) {
      throw const FormatException('Invalid service info: missing relay endpoint');
    }

    return TurnRelayGatewayServiceInfo(
      serviceId: serviceId,
      relayAddress: relayAddress,
      relayPort: relayPort,
      description: json['description'] as String?,
      clientAddress: json['clientAddress'] as String?,
      clientPort: (json['clientPort'] as num?)?.toInt(),
      updatedAt: json['updatedAt'] as String?,
    );
  }

  static const RpcCodec<TurnRelayGatewayServiceInfo> codec =
      RpcCodec<TurnRelayGatewayServiceInfo>.withDecoder(
    TurnRelayGatewayServiceInfo.fromJson,
  );
}

/// Codec used to decode lists of [TurnRelayGatewayServiceInfo] entries.
final RpcCodec<RpcList<TurnRelayGatewayServiceInfo>> _gatewayServiceListCodec =
    RpcCodec<RpcList<TurnRelayGatewayServiceInfo>>(
  RpcList.fromJson<TurnRelayGatewayServiceInfo>(
    TurnRelayGatewayServiceInfo.fromJson,
  ),
);

/// RPC request that instructs the gateway to send a payload via TURN.
class TurnRelayGatewaySendRequest implements IRpcSerializable {
  TurnRelayGatewaySendRequest({
    required this.peerAddress,
    required this.peerPort,
    required this.payload,
  });

  final String peerAddress;
  final int peerPort;
  final Uint8List payload;

  /// Serializes the send request into JSON, encoding the payload as base64.
  Map<String, dynamic> toJson() => {
        'peerAddress': peerAddress,
        'peerPort': peerPort,
        'payload': base64Encode(payload),
      };

  /// Deserializes a send request from JSON.
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

/// Wrapper around raw byte payloads exchanged over the RPC channel.
class TurnRelayGatewayBinaryFrame implements IRpcSerializable {
  TurnRelayGatewayBinaryFrame({required this.data});

  final Uint8List data;

  /// Encodes the binary frame into a base64 string for JSON transport.
  Map<String, dynamic> toJson() => {
        'data': base64Encode(data),
      };

  /// Decodes a binary frame from its JSON representation.
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

/// Helper extension that silences analysis warnings for intentionally ignored
/// futures.
extension on Future<void> {
  /// Forgets the future without awaiting it.
  void ignore() {
    unawaited(this);
  }
}
