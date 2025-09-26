// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'turn_allocation.dart';
import 'turn_message.dart';
import 'turn_relay_logger.dart';

/// TURN relay server implementation following RFC 5766 for UDP relaying.
///
/// The server listens for TURN requests on [bindAddress]/[bindPort], manages
/// allocations and permissions, and forwards peer traffic back to clients using
/// Data indications or ChannelData messages depending on active channel
/// bindings.
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
  }) : relayAddress = relayAddress ?? bindAddress,
        _logger = logger?.child('TurnRelayServer');

  /// Address used for the TURN UDP listener.
  final InternetAddress bindAddress;

  /// Port used for the TURN UDP listener (0 enables OS-assigned port).
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

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  final Map<String, _TurnRelayAllocationContext> _allocations = {};

  /// Returns true once the UDP socket has been created.
  bool get isRunning => _socket != null;

  /// Actual port of the bound UDP socket (may differ from [bindPort]).
  int get port => _socket?.port ?? bindPort;

  /// Active allocations for debugging and metrics purposes.
  Iterable<TurnAllocation> get allocations =>
      _allocations.values.map((context) => context.allocation);

  /// Starts the UDP listener and begins processing TURN requests.
  Future<void> start() async {
    if (isRunning) {
      return;
    }

    _logger?.info(
      'Starting TURN relay on ${bindAddress.address}:$bindPort',
    );

    final socket = await RawDatagramSocket.bind(bindAddress, bindPort);
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = true;
    _socket = socket;

    _subscription = socket.listen(
      _handleSocketEvent,
      onError: (Object error, StackTrace stackTrace) {
        _logger?.error(
          'TURN relay socket error',
          error: error,
          stackTrace: stackTrace,
        );
      },
      onDone: () {
        _logger?.info('TURN relay socket closed');
        stop();
      },
    );
  }

  /// Stops the UDP listener and disposes all active allocations.
  Future<void> stop() async {
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;

    for (final context in _allocations.values) {
      await context.dispose();
    }

    _allocations.clear();
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    while (true) {
      final datagram = _socket?.receive();
      if (datagram == null) {
        break;
      }
      _handleDatagram(datagram);
    }
  }

  void _handleDatagram(Datagram datagram) {
    final bytes = Uint8List.fromList(datagram.data);
    if (bytes.isEmpty) {
      return;
    }

    // ChannelData packets use a different framing (RFC 5766 section 10).
    if (_isChannelData(bytes)) {
      _handleChannelData(bytes, datagram.address, datagram.port);
      return;
    }

    final message = TurnMessage.decode(bytes);
    if (message == null) {
      _logger?.warning(
        'Invalid TURN message from ${datagram.address.address}:${datagram.port}',
      );
      return;
    }

    switch (message.messageClass) {
      case TurnMessageClass.request:
        _handleRequest(message, datagram.address, datagram.port);
        break;
      case TurnMessageClass.indication:
        _handleIndication(message, datagram.address, datagram.port);
        break;
      case TurnMessageClass.successResponse:
      case TurnMessageClass.errorResponse:
        _logger?.warning(
          'Unexpected TURN response from ${datagram.address.address}:${datagram.port}',
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
        unawaited(
          _processAllocateRequest(message, clientAddress, clientPort),
        );
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
          reason: 'Unsupported method ${message.method}',
        );
        break;
    }
  }

  Future<void> _processAllocateRequest(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) async {
    final key = _allocationKey(clientAddress, clientPort);
    var context = _allocations[key];

    if (context != null && !context.allocation.isExpired) {
      context.allocation.refresh(allocationLifetime);
      _sendAllocateSuccess(message, context, clientAddress, clientPort);
      return;
    }

    if (context != null) {
      await context.dispose();
      _allocations.remove(key);
    }

    final relaySocket = await RawDatagramSocket.bind(relayAddress, 0);

    late final _TurnRelayAllocationContext allocationContext;

    final allocation = TurnAllocation(
      clientAddress: clientAddress,
      clientPort: clientPort,
      socket: relaySocket,
      relayAddress: relayAddress,
      defaultLifetime: allocationLifetime,
      permissionLifetime: permissionLifetime,
      channelLifetime: channelLifetime,
      logger: _logger?.child('Allocation'),
      onPeerData: (Uint8List data, InternetAddress peerAddress, int peerPort) {
        _forwardPeerData(
          allocationContext,
          data,
          peerAddress,
          peerPort,
        );
      },
      onExpired: () {
        _logger?.info(
          'Allocation expired for ${clientAddress.address}:$clientPort',
        );
        _closeAllocation(key);
      },
    );

    allocationContext = _TurnRelayAllocationContext(
      clientAddress: clientAddress,
      clientPort: clientPort,
      allocation: allocation,
    );

    _allocations[key] = allocationContext;
    _sendAllocateSuccess(message, allocationContext, clientAddress, clientPort);
  }

  void _forwardPeerData(
    _TurnRelayAllocationContext context,
    Uint8List data,
    InternetAddress peerAddress,
    int peerPort,
  ) {
    final channel = context.allocation.findChannelByPeer(peerAddress, peerPort);
    if (channel != null) {
      final frame = _encodeChannelData(channel.channelNumber, data);
      _socket?.send(frame, context.clientAddress, context.clientPort);
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

    _socket?.send(
      indication.encode(),
      context.clientAddress,
      context.clientPort,
    );
  }

  void _closeAllocation(String key) {
    final context = _allocations.remove(key);
    if (context == null) {
      return;
    }
    unawaited(context.dispose());
  }

  void _handleRefreshRequest(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final context = _allocations[_allocationKey(clientAddress, clientPort)];
    if (context == null) {
      _sendError(
        message,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final lifetimeAttr = message.firstAttribute(TurnAttributeType.lifetime);
    final requestedLifetime =
        lifetimeAttr != null ? decodeLifetime(lifetimeAttr) : allocationLifetime;

    if (requestedLifetime.inSeconds == 0) {
      _closeAllocation(_allocationKey(clientAddress, clientPort));
      final response = message.buildSuccessResponse([]);
      _sendTurnMessage(response, clientAddress, clientPort);
      return;
    }

    context.allocation.refresh(requestedLifetime);
    final response = message.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(requestedLifetime),
      ),
    ]);
    _sendTurnMessage(response, clientAddress, clientPort);
  }

  void _handleCreatePermissionRequest(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final context = _allocations[_allocationKey(clientAddress, clientPort)];
    if (context == null) {
      _sendError(
        message,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final peers = message.attributesOfType(TurnAttributeType.xorPeerAddress);
    for (final peerAttr in peers) {
      final (peerAddress, _) = decodeXorAddress(peerAttr, message.transactionId);
      context.allocation.addPermission(peerAddress);
    }

    final response = message.buildSuccessResponse([]);
    _sendTurnMessage(response, clientAddress, clientPort);
  }

  void _handleChannelBindRequest(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final context = _allocations[_allocationKey(clientAddress, clientPort)];
    if (context == null) {
      _sendError(
        message,
        clientAddress,
        clientPort,
        code: 437,
        reason: 'Allocation mismatch',
      );
      return;
    }

    final channelAttr = message.firstAttribute(TurnAttributeType.channelNumber);
    final peerAttr = message.firstAttribute(TurnAttributeType.xorPeerAddress);

    if (channelAttr == null || peerAttr == null) {
      _sendError(
        message,
        clientAddress,
        clientPort,
        code: 400,
        reason: 'Missing channel binding attributes',
      );
      return;
    }

    final channelNumber = decodeChannelNumber(channelAttr);
    final (peerAddress, peerPort) =
        decodeXorAddress(peerAttr, message.transactionId);
    context.allocation.bindChannel(channelNumber, peerAddress, peerPort);

    final response = message.buildSuccessResponse([
      TurnAttribute(
        TurnAttributeType.lifetime,
        encodeLifetime(channelLifetime),
      ),
    ]);
    _sendTurnMessage(response, clientAddress, clientPort);
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
        _logger?.warning(
          'Unsupported indication ${message.method} from ${clientAddress.address}:$clientPort',
        );
        break;
    }
  }

  void _handleSendIndication(
    TurnMessage message,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final context = _allocations[_allocationKey(clientAddress, clientPort)];
    if (context == null) {
      _logger?.warning(
        'Send indication without allocation from ${clientAddress.address}:$clientPort',
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
    if (!context.allocation.hasPermission(peerAddress)) {
      _logger?.warning(
        'Permission missing for peer ${peerAddress.address}',
      );
      return;
    }

    context.allocation.sendToPeer(
      Uint8List.fromList(dataAttr),
      peerAddress,
      peerPort,
    );
  }

  void _handleChannelData(
    Uint8List packet,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    if (packet.length < 4) {
      return;
    }

    final header = ByteData.sublistView(packet, 0, 4);
    final channelNumber = header.getUint16(0);
    final length = header.getUint16(2);

    if (packet.length < 4 + length) {
      return;
    }

    final payload = Uint8List.fromList(packet.sublist(4, 4 + length));

    final context = _allocations[_allocationKey(clientAddress, clientPort)];
    if (context == null) {
      _logger?.warning(
        'ChannelData without allocation from ${clientAddress.address}:$clientPort',
      );
      return;
    }

    final binding = context.allocation.getChannel(channelNumber);
    if (binding == null) {
      _logger?.warning('Unknown channel $channelNumber from client');
      return;
    }

    context.allocation.sendToPeer(
      payload,
      binding.peerAddress,
      binding.peerPort,
    );
  }

  void _sendAllocateSuccess(
    TurnMessage request,
    _TurnRelayAllocationContext context,
    InternetAddress clientAddress,
    int clientPort,
  ) {
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorRelayedAddress,
        encodeXorAddress(
          context.allocation.relayAddress,
          context.allocation.relayPort,
          request.transactionId,
        ),
      ),
      TurnAttribute(
        TurnAttributeType.xorMappedAddress,
        encodeXorAddress(clientAddress, clientPort, request.transactionId),
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
    _sendTurnMessage(response, clientAddress, clientPort);
  }

  void _sendError(
    TurnMessage request,
    InternetAddress clientAddress,
    int clientPort, {
    required int code,
    required String reason,
  }) {
    final response = request.buildErrorResponse(code: code, reason: reason);
    _sendTurnMessage(response, clientAddress, clientPort);
  }

  void _sendTurnMessage(
    TurnMessage message,
    InternetAddress address,
    int port,
  ) {
    final encoded = message.encode();
    _socket?.send(encoded, address, port);
  }

  static bool _isChannelData(Uint8List data) =>
      data.length >= 4 && (data[0] & 0xC0) == 0x40;

  static Uint8List _encodeChannelData(int channelNumber, Uint8List payload) {
    final length = payload.length;
    final paddedLength = (length + 3) & ~3;
    final buffer = Uint8List(4 + paddedLength);
    final header = ByteData.sublistView(buffer, 0, 4);
    header.setUint16(0, channelNumber);
    header.setUint16(2, length);
    buffer.setRange(4, 4 + length, payload);
    return buffer;
  }

  String _allocationKey(InternetAddress address, int port) =>
      '${address.address}:$port';
}

final class _TurnRelayAllocationContext {
  _TurnRelayAllocationContext({
    required this.clientAddress,
    required this.clientPort,
    required this.allocation,
  });

  final InternetAddress clientAddress;
  final int clientPort;
  final TurnAllocation allocation;

  Future<void> dispose() async {
    allocation.close();
  }
}
