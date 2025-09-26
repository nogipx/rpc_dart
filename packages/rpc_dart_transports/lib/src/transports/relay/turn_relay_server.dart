// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'turn_allocation.dart';
import 'turn_message.dart';
import 'turn_relay_logger.dart';
import 'turn_tcp_frame.dart';

/// TURN relay server implementation following RFC 5766 for TCP-connected
/// clients relaying UDP or TCP peer traffic.
final class TurnRelayServer {
  TurnRelayServer({
    required this.bindAddress,
    required this.bindPort,
    InternetAddress? relayAddress,
    this.allocationLifetime = const Duration(minutes: 10),
    this.permissionLifetime = const Duration(minutes: 5),
    this.channelLifetime = const Duration(minutes: 10),
    this.software = 'turn_relay/0.1.0',
    TurnRelayLogger? logger,
  })  : relayAddress = relayAddress ?? bindAddress,
        _logger = logger?.child('TurnRelayServer');

  /// Address used for the TURN TCP listener.
  final InternetAddress bindAddress;

  /// Port used for the TURN TCP listener (0 enables OS-assigned port).
  final int bindPort;

  /// Public relay address advertised via XOR-RELAYED-ADDRESS.
  final InternetAddress relayAddress;

  /// Default allocation lifetime when client does not request a value.
  final Duration allocationLifetime;

  /// Permission lifetime according to RFC 5766 section 8.
  final Duration permissionLifetime;

  /// Channel binding lifetime according to RFC 5766 section 11.
  final Duration channelLifetime;

  /// Value exposed through the SOFTWARE attribute.
  final String software;

  final TurnRelayLogger? _logger;

  ServerSocket? _socket;
  StreamSubscription<Socket>? _listener;

  final Map<String, _TurnRelayConnectionContext> _connections = {};
  final Map<String, _TurnRelayConnectionContext> _allocationsByRelay = {};

  /// Returns true once the TCP listener has been created.
  bool get isRunning => _socket != null;

  /// Actual port of the bound TCP listener (may differ from [bindPort]).
  int get port => _socket?.port ?? bindPort;

  /// Active allocations for debugging and metrics purposes.
  Iterable<TurnAllocation> get allocations => _connections.values
      .map((context) => context.allocation)
      .whereType<TurnAllocation>();

  /// Starts the TCP listener and begins processing TURN requests.
  Future<void> start() async {
    if (isRunning) {
      return;
    }

    _logger?.info(
      'Starting TURN relay (TCP) on ${bindAddress.address}:$bindPort',
    );

    final server = await ServerSocket.bind(bindAddress, bindPort);
    _socket = server;

    _listener = server.listen(
      _handleConnection,
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'TURN relay listener error',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _logger?.info('TURN relay listener closed');
        unawaited(stop());
      },
    );
  }

  /// Stops the TCP listener and disposes all active allocations.
  Future<void> stop() async {
    await _listener?.cancel();
    _listener = null;
    await _socket?.close();
    _socket = null;

    final contexts = _connections.values.toList();
    _connections.clear();
    _allocationsByRelay.clear();
    for (final context in contexts) {
      await context.dispose();
    }
  }

  void _handleConnection(Socket socket) {
    final key = _allocationKey(socket.remoteAddress, socket.remotePort);
    _logger?.debug('Accepted connection from $key');

    final connectionLogger = _logger?.child('Connection $key');
    final context = _TurnRelayConnectionContext(
      socket: socket,
      logger: connectionLogger,
    );

    _connections[key] = context;

    context.start(
      onTurnMessage: (TurnMessage message) {
        _handleTurnMessage(context, message);
      },
      onChannelData: (int channelNumber, Uint8List payload) {
        _handleChannelData(context, channelNumber, payload);
      },
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'TURN connection error for $key',
          error: error,
          stackTrace: stackTrace,
        );
        unawaited(_closeConnection(context));
      },
      onClosed: () {
        _logger?.debug('Connection closed for $key');
        unawaited(_closeConnection(context));
      },
    );
  }

  Future<void> _closeConnection(_TurnRelayConnectionContext context) async {
    final key = _allocationKey(context.clientAddress, context.clientPort);
    if (_connections.remove(key) == null) {
      return;
    }

    final allocation = context.allocation;
    if (allocation != null) {
      _unregisterAllocation(allocation);
    }

    await context.dispose();
  }

  void _handleTurnMessage(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    switch (message.messageClass) {
      case TurnMessageClass.request:
        _handleRequest(context, message);
        break;
      case TurnMessageClass.indication:
        _handleIndication(context, message);
        break;
      case TurnMessageClass.successResponse:
      case TurnMessageClass.errorResponse:
        _logger?.warning(
          'Unexpected TURN response from ${context.clientAddress.address}:${context.clientPort}',
        );
        break;
    }
  }

  void _handleRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    switch (message.method) {
      case TurnMethod.allocate:
        unawaited(_processAllocateRequest(context, message));
        break;
      case TurnMethod.refresh:
        _handleRefreshRequest(context, message);
        break;
      case TurnMethod.createPermission:
        _handleCreatePermissionRequest(context, message);
        break;
      case TurnMethod.channelBind:
        _handleChannelBindRequest(context, message);
        break;
      case TurnMethod.connectRequest:
        _handleConnectRequest(context, message);
        break;
      default:
        _sendError(
          context,
          message,
          code: 420,
          reason: 'Unsupported method ${message.method}',
        );
        break;
    }
  }

  Future<void> _processAllocateRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) async {
    final existing = context.allocation;
    if (existing != null && !existing.isExpired) {
      existing.refresh(allocationLifetime);
      _registerAllocation(context, existing);
      _sendAllocateSuccess(context, message, existing);
      return;
    }

    if (existing != null) {
      _unregisterAllocation(existing);
      existing.close();
    }
    context.allocation = null;

    final requestedTransportAttr =
        message.firstAttribute(TurnAttributeType.requestedTransport);
    final requestedTransport = requestedTransportAttr != null
        ? decodeRequestedTransport(requestedTransportAttr)
        : TurnRequestedTransport.udp;

    late final TurnRelayTransportProtocol protocol;
    switch (requestedTransport) {
      case TurnRequestedTransport.udp:
        protocol = TurnRelayTransportProtocol.udp;
        break;
      case TurnRequestedTransport.tcp:
        protocol = TurnRelayTransportProtocol.tcp;
        break;
      default:
        _sendError(
          context,
          message,
          code: 442,
          reason: 'Unsupported REQUESTED-TRANSPORT $requestedTransport',
        );
        return;
    }

    late final TurnAllocation allocation;
    switch (protocol) {
      case TurnRelayTransportProtocol.udp:
        final relaySocket = await RawDatagramSocket.bind(relayAddress, 0);
        allocation = TurnAllocation.udp(
          clientAddress: context.clientAddress,
          clientPort: context.clientPort,
          socket: relaySocket,
          relayAddress: relayAddress,
          defaultLifetime: allocationLifetime,
          permissionLifetime: permissionLifetime,
          channelLifetime: channelLifetime,
          logger: _logger?.child('Allocation'),
          onPeerData:
              (Uint8List data, InternetAddress peerAddress, int peerPort) {
            _forwardPeerData(context, data, peerAddress, peerPort);
          },
          onExpired: () {
            _logger?.info(
              'Allocation expired for ${context.clientAddress.address}:${context.clientPort}',
            );
            _unregisterAllocation(allocation);
            context.allocation = null;
          },
        );
        break;
      case TurnRelayTransportProtocol.tcp:
        final listener = await ServerSocket.bind(relayAddress, 0);
        allocation = TurnAllocation.tcp(
          clientAddress: context.clientAddress,
          clientPort: context.clientPort,
          serverSocket: listener,
          relayAddress: relayAddress,
          defaultLifetime: allocationLifetime,
          permissionLifetime: permissionLifetime,
          channelLifetime: channelLifetime,
          logger: _logger?.child('Allocation'),
          onPeerData:
              (Uint8List data, InternetAddress peerAddress, int peerPort) {
            _forwardPeerData(context, data, peerAddress, peerPort);
          },
          onExpired: () {
            _logger?.info(
              'Allocation expired for ${context.clientAddress.address}:${context.clientPort}',
            );
            _unregisterAllocation(allocation);
            context.allocation = null;
          },
        );
        break;
    }

    context.allocation = allocation;
    _registerAllocation(context, allocation);
    _sendAllocateSuccess(context, message, allocation);
  }

  void _forwardPeerData(
    _TurnRelayConnectionContext context,
    Uint8List data,
    InternetAddress peerAddress,
    int peerPort,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      return;
    }

    final channel = allocation.findChannelByPeer(peerAddress, peerPort);
    if (channel != null) {
      context.send(encodeChannelDataFrame(channel.channelNumber, data));
      return;
    }

    final transactionId = TurnMessage.generateTransactionId();
    final indication = TurnMessage(
      method: TurnMethod.data,
      messageClass: TurnMessageClass.indication,
      transactionId: transactionId,
      attributes: [
        TurnAttribute(
          TurnAttributeType.xorPeerAddress,
          encodeXorAddress(peerAddress, peerPort, transactionId),
        ),
        TurnAttribute(TurnAttributeType.data, encodeData(data)),
      ],
    );

    context.send(indication.encode());
  }

  void _handleRefreshRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final lifetimeAttr = message.firstAttribute(TurnAttributeType.lifetime);
    final requestedLifetime = lifetimeAttr != null
        ? decodeLifetime(lifetimeAttr)
        : allocationLifetime;

    if (requestedLifetime.inSeconds == 0) {
      _unregisterAllocation(allocation);
      context.allocation = null;
      allocation.close();
      final response = message.buildSuccessResponse([]);
      _sendTurnMessage(context, response);
      return;
    }

    allocation.refresh(requestedLifetime);
    final response = message.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(requestedLifetime),
      ),
    ]);
    _sendTurnMessage(context, response);
  }

  void _handleCreatePermissionRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final peers = message.attributesOfType(TurnAttributeType.xorPeerAddress);
    for (final peerAttr in peers) {
      final (peerAddress, peerPort) =
          decodeXorAddress(peerAttr, message.transactionId);
      allocation.addPermission(peerAddress, peerPort);
    }

    final response = message.buildSuccessResponse([]);
    _sendTurnMessage(context, response);
  }

  void _handleChannelBindRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final channelAttr = message.firstAttribute(TurnAttributeType.channelNumber);
    final peerAttr = message.firstAttribute(TurnAttributeType.xorPeerAddress);

    if (channelAttr == null || peerAttr == null) {
      _sendError(
        context,
        message,
        code: 400,
        reason: 'CHANNEL-NUMBER or XOR-PEER-ADDRESS missing',
      );
      return;
    }

    final channelNumber = ByteData.sublistView(channelAttr).getUint16(0);
    final (peerAddress, peerPort) =
        decodeXorAddress(peerAttr, message.transactionId);

    allocation.bindChannel(channelNumber, peerAddress, peerPort);
    final response = message.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(channelLifetime),
      ),
    ]);
    _sendTurnMessage(context, response);
  }

  void _handleConnectRequest(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    final sourceAllocation = context.allocation;
    if (sourceAllocation == null || sourceAllocation.isExpired) {
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final peerAttr = message.firstAttribute(TurnAttributeType.xorPeerAddress);
    if (peerAttr == null) {
      _sendError(
        context,
        message,
        code: 400,
        reason: 'XOR-PEER-ADDRESS missing',
      );
      return;
    }

    final (peerAddress, peerPort) =
        decodeXorAddress(peerAttr, message.transactionId);
    final targetContext = _allocationsByRelay[_relayKey(peerAddress, peerPort)];
    final targetAllocation = targetContext?.allocation;
    if (targetContext == null || targetAllocation == null) {
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Target allocation not found',
      );
      return;
    }

    if (targetAllocation.isExpired) {
      _unregisterAllocation(targetAllocation);
      targetContext.allocation = null;
      targetAllocation.close();
      _sendError(
        context,
        message,
        code: 437,
        reason: 'Target allocation expired',
      );
      return;
    }

    final response = message.buildSuccessResponse([]);
    _sendTurnMessage(context, response);

    final notificationTx = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorPeerAddress,
        encodeXorAddress(
          sourceAllocation.relayAddress,
          sourceAllocation.relayPort,
          notificationTx,
        ),
      ),
      TurnAttribute(
        TurnAttributeType.xorMappedAddress,
        encodeXorAddress(
          context.clientAddress,
          context.clientPort,
          notificationTx,
        ),
      ),
    ];

    final payloadAttr = message.firstAttribute(TurnAttributeType.data);
    if (payloadAttr != null) {
      attributes.add(
        TurnAttribute(TurnAttributeType.data, Uint8List.fromList(payloadAttr)),
      );
    }

    final indication = TurnMessage(
      method: TurnMethod.connectRequest,
      messageClass: TurnMessageClass.indication,
      transactionId: notificationTx,
      attributes: attributes,
    );

    targetContext.send(indication.encode());
  }

  void _handleIndication(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    switch (message.method) {
      case TurnMethod.send:
        _handleSendIndication(context, message);
        break;
      default:
        _logger?.warning(
          'Unsupported indication ${message.method} from ${context.clientAddress.address}:${context.clientPort}',
        );
        break;
    }
  }

  void _handleSendIndication(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      _logger?.warning(
        'Send indication without allocation from ${context.clientAddress.address}:${context.clientPort}',
      );
      return;
    }

    final dataAttr = message.firstAttribute(TurnAttributeType.data);
    if (dataAttr == null) {
      _logger?.warning('TURN send indication without DATA attribute');
      return;
    }

    final peerAttr = message.firstAttribute(TurnAttributeType.xorPeerAddress);
    if (peerAttr == null) {
      _logger?.warning('TURN send indication without XOR-PEER-ADDRESS');
      return;
    }

    final (peerAddress, peerPort) =
        decodeXorAddress(peerAttr, message.transactionId);
    if (!allocation.hasPermission(peerAddress, peerPort)) {
      _logger?.warning(
        'Permission missing for peer ${peerAddress.address}',
      );
      return;
    }

    allocation.sendToPeer(
      Uint8List.fromList(dataAttr),
      peerAddress,
      peerPort,
    );
  }

  void _handleChannelData(
    _TurnRelayConnectionContext context,
    int channelNumber,
    Uint8List payload,
  ) {
    final allocation = context.allocation;
    if (allocation == null) {
      _logger?.warning(
        'ChannelData without allocation from ${context.clientAddress.address}:${context.clientPort}',
      );
      return;
    }

    final binding = allocation.getChannel(channelNumber);
    if (binding == null) {
      _logger?.warning('Unknown channel $channelNumber from client');
      return;
    }

    allocation.sendToPeer(
      payload,
      binding.peerAddress,
      binding.peerPort,
    );
  }

  void _sendAllocateSuccess(
    _TurnRelayConnectionContext context,
    TurnMessage request,
    TurnAllocation allocation,
  ) {
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorRelayedAddress,
        encodeXorAddress(
          allocation.relayAddress,
          allocation.relayPort,
          request.transactionId,
        ),
      ),
      TurnAttribute(
        TurnAttributeType.xorMappedAddress,
        encodeXorAddress(
          context.clientAddress,
          context.clientPort,
          request.transactionId,
        ),
      ),
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(allocationLifetime),
      ),
      TurnAttribute(
        TurnAttributeType.software,
        Uint8List.fromList(software.codeUnits),
      ),
    ];

    final response = request.buildSuccessResponse(attributes);
    _sendTurnMessage(context, response);
  }

  void _sendError(
    _TurnRelayConnectionContext context,
    TurnMessage request, {
    required int code,
    required String reason,
  }) {
    final response = request.buildErrorResponse(code: code, reason: reason);
    _sendTurnMessage(context, response);
  }

  void _sendTurnMessage(
    _TurnRelayConnectionContext context,
    TurnMessage message,
  ) {
    context.send(message.encode());
  }

  void _registerAllocation(
    _TurnRelayConnectionContext context,
    TurnAllocation allocation,
  ) {
    final key = _relayKey(allocation.relayAddress, allocation.relayPort);
    _allocationsByRelay[key] = context;
  }

  void _unregisterAllocation(TurnAllocation allocation) {
    final key = _relayKey(allocation.relayAddress, allocation.relayPort);
    final owner = _allocationsByRelay[key];
    if (owner?.allocation == allocation) {
      _allocationsByRelay.remove(key);
    }
  }

  static String _allocationKey(InternetAddress address, int port) =>
      '${address.address}:$port';

  static String _relayKey(InternetAddress address, int port) =>
      '${address.address}:$port';
}

final class _TurnRelayConnectionContext {
  _TurnRelayConnectionContext({
    required this.socket,
    this.logger,
  });

  final Socket socket;
  final TurnRelayLogger? logger;

  StreamSubscription<Uint8List>? _subscription;
  TurnTcpFrameDecoder? _decoder;
  bool _disposed = false;

  TurnAllocation? allocation;

  InternetAddress get clientAddress => socket.remoteAddress;
  int get clientPort => socket.remotePort;

  void start({
    required void Function(TurnMessage message) onTurnMessage,
    required void Function(int channelNumber, Uint8List payload) onChannelData,
    required void Function(Object error, StackTrace stackTrace) onError,
    required void Function() onClosed,
  }) {
    _decoder = TurnTcpFrameDecoder(
      onTurnMessage: onTurnMessage,
      onChannelData: onChannelData,
    );

    _subscription = socket.listen(
      (Uint8List data) {
        if (data.isEmpty) {
          return;
        }
        _decoder?.addChunk(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        logger?.error(
          'TURN TCP connection error',
          error: error,
          stackTrace: stackTrace,
        );
        onError(error, stackTrace);
      },
      onDone: onClosed,
      cancelOnError: false,
    );
  }

  void send(Uint8List data) {
    socket.add(data);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _subscription?.cancel();
    allocation?.close();
    await socket.close();
  }
}
