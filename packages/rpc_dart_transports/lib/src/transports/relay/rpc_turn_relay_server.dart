// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'turn_allocation.dart';
import 'turn_message.dart';

/// Lightweight TURN relay server powered by rpc_dart infrastructure.
///
/// Implements a subset of RFC 5766 to support UDP relay allocations, permissions
/// and channel bindings. The relay is transport agnostic and can be embedded
/// inside rpc_dart applications.
final class RpcTurnRelayServer {
  RpcTurnRelayServer({
    required this.bindAddress,
    required this.port,
    InternetAddress? relayAddress,
    this.allocationLifetime = const Duration(minutes: 10),
    this.permissionLifetime = const Duration(minutes: 5),
    this.channelLifetime = const Duration(minutes: 10),
    this.logger,
    this.software = 'rpc_dart_turn_relay/0.1.0',
  }) : relayAddress = relayAddress ?? bindAddress;

  /// Address used for the TURN UDP listener.
  final InternetAddress bindAddress;

  /// UDP port for the TURN listener.
  final int port;

  /// Public address announced as relayed address to clients.
  final InternetAddress relayAddress;

  /// Default allocation lifetime (RFC 5766 recommends 10 minutes).
  final Duration allocationLifetime;

  /// Permission lifetime (RFC 5766 section 9.2).
  final Duration permissionLifetime;

  /// Channel binding lifetime (RFC 5766 section 11).
  final Duration channelLifetime;

  /// Logger for diagnostics.
  final RpcLogger? logger;

  /// Software attribute value returned in success responses.
  final String software;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  final Map<String, TurnAllocation> _allocations = {};

  bool get isRunning => _socket != null;

  /// Actual UDP port the server is bound to. Useful when binding to port 0.
  int get listenPort => _socket?.port ?? port;

  /// Starts the TURN relay server.
  Future<void> start() async {
    if (isRunning) return;

    logger?.info('Starting TURN relay on ${bindAddress.address}:$port');
    final socket = await RawDatagramSocket.bind(bindAddress, port);
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = false;

    _socket = socket;
    _subscription = socket.listen(
      _handleSocketEvent,
      onError: (error, stackTrace) {
        logger?.error(
          'TURN relay socket error',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        logger?.info('TURN relay socket closed');
        stop();
      },
    );
  }

  /// Stops the TURN relay server and closes all active allocations.
  Future<void> stop() async {
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;

    for (final allocation in _allocations.values) {
      allocation.close();
    }
    _allocations.clear();
  }

  Iterable<TurnAllocation> get allocations => _allocations.values;

  void _handleSocketEvent(RawSocketEvent event) {
    if (event == RawSocketEvent.read) {
      while (true) {
        final datagram = _socket?.receive();
        if (datagram == null) {
          break;
        }
        _handleDatagram(datagram);
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    final data = datagram.data;
    if (data.isEmpty) {
      return;
    }

    final clientAddress = datagram.address;
    final clientPort = datagram.port;

    // ChannelData message detection (RFC 5766 section 11.5)
    final firstByte = data[0];
    if ((firstByte & 0xC0) == 0x40) {
      _handleChannelData(data, clientAddress, clientPort);
      return;
    }

    final message = TurnMessage.decode(Uint8List.fromList(data));
    if (message == null) {
      logger?.warning('Received invalid TURN message from ${clientAddress.address}:$clientPort');
      return;
    }

    switch (message.messageClass) {
      case TurnMessageClass.request:
        _handleRequest(message, clientAddress, clientPort);
        break;
      case TurnMessageClass.indication:
        _handleIndication(message, clientAddress, clientPort);
        break;
      case TurnMessageClass.successResponse:
      case TurnMessageClass.errorResponse:
        // Clients should not send responses to the server.
        logger?.warning(
          'Unexpected TURN response from ${clientAddress.address}:$clientPort',
        );
        break;
    }
  }

  void _handleRequest(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    switch (message.method) {
      case TurnMethod.allocate:
        _handleAllocateRequest(message, clientAddress, clientPort);
        break;
      case TurnMethod.refresh:
        _handleRefreshRequest(message, clientAddress, clientPort);
        break;
      case TurnMethod.createPermission:
        _handleCreatePermissionRequest(message, clientAddress, clientPort);
        break;
      case TurnMethod.channelBind:
        _handleChannelBindRequest(message, clientAddress, clientPort);
        break;
      default:
        _sendError(
          message,
          clientAddress,
          clientPort,
          code: 420,
          reason: 'Unknown request method ${message.method}',
        );
        break;
    }
  }

  void _handleIndication(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    switch (message.method) {
      case TurnMethod.send:
        _handleSendIndication(message, clientAddress, clientPort);
        break;
      default:
        logger?.warning(
          'Unsupported indication method ${message.method} from ${clientAddress.address}:$clientPort',
        );
        break;
    }
  }

  void _handleAllocateRequest(
    TurnMessage request,
    InternetAddress clientAddress,
    int clientPort,
  ) async {
    final key = _allocationKey(clientAddress, clientPort);
    if (_allocations.containsKey(key)) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation already exists',
      );
      return;
    }

    final requestedTransport = request.firstAttribute(TurnAttributeType.requestedTransport);
    if (requestedTransport == null || requestedTransport.isEmpty) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 400,
        reason: 'REQUESTED-TRANSPORT missing',
      );
      return;
    }

    if (requestedTransport[0] != TurnRequestedTransport.udp) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 442,
        reason: 'Only UDP transport is supported',
      );
      return;
    }

    final socket = await RawDatagramSocket.bind(relayAddress, 0);
    final allocationLogger = logger?.child('Allocation-${clientAddress.address}:$clientPort');
    final allocation = TurnAllocation(
      clientAddress: clientAddress,
      clientPort: clientPort,
      socket: socket,
      relayAddress: relayAddress,
      defaultLifetime: allocationLifetime,
      permissionLifetime: permissionLifetime,
      channelLifetime: channelLifetime,
      logger: allocationLogger,
      onPeerData: (payload, peerAddress, peerPort) {
        _sendPeerData(allocation, payload, peerAddress, peerPort);
      },
      onExpired: () {
        _allocations.remove(key);
      },
    );

    _allocations[key] = allocation;

    final successAttributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorRelayedAddress,
        encodeXorAddress(
          relayAddress,
          allocation.relayPort,
          request.transactionId,
        ),
      ),
      TurnAttribute(
        TurnAttributeType.xorMappedAddress,
        encodeXorAddress(
          clientAddress,
          clientPort,
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

    final response = request.buildSuccessResponse(successAttributes);
    _sendMessage(response, clientAddress, clientPort);
  }

  void _handleRefreshRequest(
    TurnMessage request,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final allocation = _findAllocation(clientAddress, clientPort);
    if (allocation == null) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation does not exist',
      );
      return;
    }

    final lifetimeAttr = request.firstAttribute(TurnAttributeType.lifetime);
    final requestedLifetime = lifetimeAttr != null
        ? decodeLifetime(lifetimeAttr)
        : allocationLifetime;

    if (requestedLifetime.inSeconds == 0) {
      allocation.close();
      _allocations.remove(_allocationKey(clientAddress, clientPort));
      final response = request.buildSuccessResponse([
        TurnAttribute(
          TurnAttributeType.lifetime,
          encodeLifetime(Duration.zero),
        ),
        TurnAttribute(
          TurnAttributeType.software,
          Uint8List.fromList(software.codeUnits),
        ),
      ]);
      _sendMessage(response, clientAddress, clientPort);
      return;
    }

    final effective = requestedLifetime < allocationLifetime
        ? requestedLifetime
        : allocationLifetime;
    allocation.refresh(effective);

    final response = request.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(effective),
      ),
      TurnAttribute(
        TurnAttributeType.software,
        Uint8List.fromList(software.codeUnits),
      ),
    ]);
    _sendMessage(response, clientAddress, clientPort);
  }

  void _handleCreatePermissionRequest(
    TurnMessage request,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final allocation = _findAllocation(clientAddress, clientPort);
    if (allocation == null) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation does not exist',
      );
      return;
    }

    var permissionAdded = false;
    for (final value in request.attributesOfType(TurnAttributeType.xorPeerAddress)) {
      final (peerAddress, _) = decodeXorAddress(value, request.transactionId);
      allocation.addPermission(peerAddress);
      permissionAdded = true;
    }

    if (!permissionAdded) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 400,
        reason: 'No XOR-PEER-ADDRESS provided',
      );
      return;
    }

    final response = request.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.software,
        Uint8List.fromList(software.codeUnits),
      ),
    ]);
    _sendMessage(response, clientAddress, clientPort);
  }

  void _handleChannelBindRequest(
    TurnMessage request,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final allocation = _findAllocation(clientAddress, clientPort);
    if (allocation == null) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation does not exist',
      );
      return;
    }

    final channelAttr = request.firstAttribute(TurnAttributeType.channelNumber);
    final peerAttr = request.firstAttribute(TurnAttributeType.xorPeerAddress);
    if (channelAttr == null || peerAttr == null) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 400,
        reason: 'Missing CHANNEL-NUMBER or XOR-PEER-ADDRESS',
      );
      return;
    }

    final channelNumber = decodeChannelNumber(channelAttr);
    if (channelNumber < 0x4000 || channelNumber > 0x7FFF) {
      _sendError(
        request,
        clientAddress,
        clientPort,
        code: 400,
        reason: 'Invalid channel number',
      );
      return;
    }

    final (peerAddress, peerPort) = decodeXorAddress(peerAttr, request.transactionId);
    allocation.bindChannel(channelNumber, peerAddress, peerPort);

    final response = request.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.software,
        Uint8List.fromList(software.codeUnits),
      ),
    ]);
    _sendMessage(response, clientAddress, clientPort);
  }

  void _handleSendIndication(
    TurnMessage indication,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final allocation = _findAllocation(clientAddress, clientPort);
    if (allocation == null) {
      logger?.warning('Send indication received without allocation from ${clientAddress.address}:$clientPort');
      return;
    }

    final peerAttr = indication.firstAttribute(TurnAttributeType.xorPeerAddress);
    final dataAttr = indication.firstAttribute(TurnAttributeType.data);

    if (peerAttr == null || dataAttr == null) {
      logger?.warning('Invalid send indication from ${clientAddress.address}:$clientPort');
      return;
    }

    final (peerAddress, peerPort) = decodeXorAddress(peerAttr, indication.transactionId);

    if (!allocation.hasPermission(peerAddress)) {
      logger?.warning(
        'Peer ${peerAddress.address} not permitted for allocation ${clientAddress.address}:$clientPort',
      );
      return;
    }

    allocation.sendToPeer(Uint8List.fromList(dataAttr), peerAddress, peerPort);
  }

  void _handleChannelData(
    Uint8List data,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    if (data.length < 4) {
      logger?.warning('Invalid ChannelData from ${clientAddress.address}:$clientPort');
      return;
    }

    final header = ByteData.sublistView(data, 0, 4);
    final channelNumber = header.getUint16(0);
    final length = header.getUint16(2);

    if (length + 4 > data.length) {
      logger?.warning('ChannelData length mismatch from ${clientAddress.address}:$clientPort');
      return;
    }

    final payload = Uint8List.fromList(data.sublist(4, 4 + length));
    final allocation = _findAllocation(clientAddress, clientPort);
    if (allocation == null) {
      logger?.warning('ChannelData received without allocation from ${clientAddress.address}:$clientPort');
      return;
    }

    final binding = allocation.getChannel(channelNumber);
    if (binding == null) {
      logger?.warning('Unknown channel $channelNumber from ${clientAddress.address}:$clientPort');
      return;
    }

    allocation.sendToPeer(payload, binding.peerAddress, binding.peerPort);
  }

  void _sendPeerData(
    TurnAllocation allocation,
    Uint8List payload,
    InternetAddress peerAddress,
    int peerPort,
  ) {
    final binding = allocation.findChannelByPeer(peerAddress, peerPort);
    if (binding != null) {
      final header = ByteData(4);
      header.setUint16(0, binding.channelNumber);
      header.setUint16(2, payload.length);
      final packet = BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(payload);
      _socket?.send(
        packet.toBytes(),
        allocation.clientAddress,
        allocation.clientPort,
      );
      return;
    }

    final indication = TurnMessage(method: TurnMethod.data, messageClass: TurnMessageClass.indication);
    final response = TurnMessage(
      method: indication.method,
      messageClass: indication.messageClass,
      transactionId: indication.transactionId,
      attributes: [
        TurnAttribute(
          TurnAttributeType.xorPeerAddress,
          encodeXorAddress(peerAddress, peerPort, indication.transactionId),
        ),
        TurnAttribute(
          TurnAttributeType.data,
          encodeData(payload),
        ),
      ],
    );

    _sendMessage(response, allocation.clientAddress, allocation.clientPort);
  }

  void _sendMessage(
    TurnMessage message,
    InternetAddress address,
    int port,
  ) {
    final bytes = message.encode();
    _socket?.send(bytes, address, port);
  }

  void _sendError(
    TurnMessage request,
    InternetAddress address,
    int port,
    {
      required int code,
      required String reason,
    }
  ) {
    final error = request.buildErrorResponse(code: code, reason: reason);
    _sendMessage(error, address, port);
  }

  TurnAllocation? _findAllocation(InternetAddress address, int port) {
    return _allocations[_allocationKey(address, port)];
  }

  String _allocationKey(InternetAddress address, int port) => '${address.address}:$port';
}
