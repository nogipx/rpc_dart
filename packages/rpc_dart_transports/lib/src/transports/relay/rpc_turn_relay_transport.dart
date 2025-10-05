// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

/// Base transport that multiplexes gRPC metadata and payload frames over a
/// [`TurnRelayClient`] connection.
abstract base class RpcTurnRelayTransportBase
    extends RpcTurnRelayStreamTransportCore {
  RpcTurnRelayTransportBase({
    required TurnRelayClient client,
    required this.peerAddress,
    required this.peerPort,
    required super.idManager,
    bool manageClientLifecycle = false,
    RpcLogger? logger,
  })  : _client = client,
        super(
          componentName: 'RpcTurnRelayTransport',
          incomingDatagrams: client.bytes,
          sendDatagram: (packet) => client.send(
            packet,
            peerAddress: peerAddress,
            peerPort: peerPort,
          ),
          onClose: manageClientLifecycle ? client.close : null,
          customHealth: () async {
            if (client.isClosed) {
              return RpcHealthStatus.degraded(
                component: 'RpcTurnRelayTransport',
                message: 'TURN relay client connection is closed',
              );
            }

            return RpcHealthStatus.healthy(
              component: 'RpcTurnRelayTransport',
              message: 'TURN relay transport ready',
            );
          },
          customReconnect: () async => RpcHealthStatus.degraded(
            component: 'RpcTurnRelayTransport',
            message: 'Reconnect is not supported for TURN relay transports',
            details: const {'supported': false},
          ),
          logger: logger?.child('RpcTurnRelayTransport'),
        );

  /// Peer address used for outbound relay traffic.
  final InternetAddress peerAddress;

  /// Peer port used for outbound relay traffic.
  final int peerPort;

  final TurnRelayClient _client;

  @override
  bool get isClosed => super.isClosed || _client.isClosed;

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) {
    // TODO: implement sendDirectObject
    throw UnimplementedError();
  }

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((e) => e.streamId == streamId);
  }
}

/// Client-side transport that uses odd stream identifiers.
final class RpcTurnRelayCallerTransport extends RpcTurnRelayTransportBase {
  RpcTurnRelayCallerTransport._({
    required super.client,
    required super.peerAddress,
    required super.peerPort,
    required super.idManager,
    super.manageClientLifecycle,
    super.logger,
  });

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
    TurnRelayClientOptions options = const TurnRelayClientOptions(),
    RpcLogger? logger,
  }) async {
    final client = await TurnRelayClient.connect(
      serverAddress: serverAddress,
      serverPort: serverPort,
      options: options,
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

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((message) => message.streamId == streamId);
  }

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) {
    throw UnsupportedError(
      'TURN relay transports do not support zero-copy object delivery',
    );
  }
}

/// Server-side transport that uses even stream identifiers.
final class RpcTurnRelayResponderTransport extends RpcTurnRelayTransportBase {
  RpcTurnRelayResponderTransport._({
    required super.client,
    required super.peerAddress,
    required super.peerPort,
    required super.idManager,
    super.manageClientLifecycle,
    super.logger,
  });

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
    TurnRelayClientOptions options = const TurnRelayClientOptions(),
    RpcLogger? logger,
  }) async {
    final client = await TurnRelayClient.connect(
      serverAddress: serverAddress,
      serverPort: serverPort,
      options: options,
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

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) {
    return incomingMessages.where((e) => e.streamId == streamId);
  }

  @override
  Future<void> sendDirectObject(int streamId, Object object,
      {bool endStream = false}) {
    throw UnimplementedError();
  }
}
