// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import '../../server/rpc_server_interface.dart';
import 'rpc_turn_relay_responder_transport.dart';
import 'turn_allocation.dart';
import 'turn_message.dart';

/// RPC TURN relay server. Оборачивает UDP relay (RFC 5766) в инфраструктуру
/// rpc_dart, создавая [RpcResponderEndpoint] для каждой TURN allocation.
final class RpcTurnRelayServer implements IRpcServer {
  RpcTurnRelayServer({
    required this.bindAddress,
    required this.bindPort,
    required List<RpcResponderContract> contracts,
    InternetAddress? relayAddress,
    this.allocationLifetime = const Duration(minutes: 10),
    this.permissionLifetime = const Duration(minutes: 5),
    this.channelLifetime = const Duration(minutes: 10),
    this.software = 'rpc_dart_turn_relay/0.1.0',
    RpcLogger? logger,
  })  : relayAddress = relayAddress ?? bindAddress,
        _logger = logger?.child('TurnRelayServer'),
        _contracts = List.unmodifiable(contracts);

  /// Адрес, на котором слушаем TURN UDP пакеты.
  final InternetAddress bindAddress;

  /// Порт для UDP listener (можно 0 для автоназначения).
  final int bindPort;

  /// Адрес, который будет возвращаться в XOR-RELAYED-ADDRESS (обычно публичный IP).
  final InternetAddress relayAddress;

  /// Жизненный цикл allocation.
  final Duration allocationLifetime;

  /// Жизненный цикл permission.
  final Duration permissionLifetime;

  /// Жизненный цикл channel binding.
  final Duration channelLifetime;

  /// Строка для TURN SOFTWARE атрибута.
  final String software;

  final RpcLogger? _logger;
  final List<RpcResponderContract> _contracts;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  final Map<String, _RpcTurnRelayAllocationContext> _allocations = {};
  final List<RpcResponderEndpoint> _endpoints = [];

  @override
  String get host => bindAddress.address;

  /// Фактический порт, на котором слушает UDP сокет.
  int get listenPort => _socket?.port ?? bindPort;

  @override
  int get port => listenPort;

  @override
  bool get isRunning => _socket != null;

  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  /// Текущие allocation (для отладки/метрик).
  Iterable<_RpcTurnRelayAllocationContext> get allocations =>
      _allocations.values;

  /// Запуск UDP listener и обработка TURN запросов.
  @override
  Future<void> start() async {
    if (isRunning) {
      return;
    }

    _logger?.info('Starting TURN relay on ${bindAddress.address}:$bindPort');
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

  @override
  Future<void> stop() async {
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;

    for (final context in _allocations.values) {
      await context.dispose();
      _endpoints.remove(context.endpoint);
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
    final bytes = datagram.data;
    if (bytes.isEmpty) {
      return;
    }

    final message = TurnMessage.decode(Uint8List.fromList(bytes));
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
        // Сервер не ожидает ответов.
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
      _endpoints.remove(context.endpoint);
    }

    final relaySocket = await RawDatagramSocket.bind(relayAddress, 0);

    late final _RpcTurnRelayAllocationContext allocationContext;

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
        _forwardPeerData(allocationContext, data, peerAddress, peerPort);
      },
      onExpired: () {
        _logger?.info('Allocation expired for ${clientAddress.address}:$clientPort');
        _closeAllocation(key);
      },
    );

    final transport = RpcTurnRelayResponderTransport(
      sendFrame: (Uint8List frame) async {
        final transactionId = TurnMessage.generateTransactionId();
        final indication = TurnMessage(
          method: TurnMethod.data,
          messageClass: TurnMessageClass.indication,
          transactionId: transactionId,
          attributes: [
            TurnAttribute(
              TurnAttributeType.xorPeerAddress,
              encodeXorAddress(
                allocation.relayAddress,
                allocation.relayPort,
                transactionId,
              ),
            ),
            TurnAttribute(TurnAttributeType.data, encodeData(frame)),
          ],
        );

        _socket?.send(
          indication.encode(),
          clientAddress,
          clientPort,
        );
      },
      logger: _logger,
    );

    final endpoint = RpcResponderEndpoint(
      transport: transport,
      debugLabel: 'turn:${clientAddress.address}:$clientPort',
      loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
    );

    for (final contract in _contracts) {
      endpoint.registerServiceContract(contract);
    }

    endpoint.start();

    allocationContext = _RpcTurnRelayAllocationContext(
      clientAddress: clientAddress,
      clientPort: clientPort,
      allocation: allocation,
      endpoint: endpoint,
      transport: transport,
    );

    _allocations[key] = allocationContext;
    _endpoints.add(endpoint);

    _sendAllocateSuccess(message, allocationContext, clientAddress, clientPort);
  }

  void _forwardPeerData(
    _RpcTurnRelayAllocationContext context,
    Uint8List data,
    InternetAddress peerAddress,
    int peerPort,
  ) {
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
    if (context == null) return;
    _endpoints.remove(context.endpoint);
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
      TurnAttribute(TurnAttributeType.lifetime, encodeLifetime(requestedLifetime)),
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
    final (peerAddress, peerPort) = decodeXorAddress(peerAttr, message.transactionId);
    context.allocation.bindChannel(channelNumber, peerAddress, peerPort);

    final response = message.buildSuccessResponse([
      TurnAttribute(TurnAttributeType.lifetime, encodeLifetime(channelLifetime)),
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
    if (peerAttr != null) {
      final (peerAddress, _) = decodeXorAddress(peerAttr, message.transactionId);
      if (!context.allocation.hasPermission(peerAddress)) {
        _logger?.warning('Permission missing for peer ${peerAddress.address}');
      }
    }

    context.transport.handleIncomingFrame(Uint8List.fromList(dataAttr));
  }

  void _sendAllocateSuccess(
    TurnMessage request,
    _RpcTurnRelayAllocationContext context,
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

  String _allocationKey(InternetAddress address, int port) =>
      '${address.address}:$port';
}

final class _RpcTurnRelayAllocationContext {
  _RpcTurnRelayAllocationContext({
    required this.clientAddress,
    required this.clientPort,
    required this.allocation,
    required this.endpoint,
    required this.transport,
  });

  final InternetAddress clientAddress;
  final int clientPort;
  final TurnAllocation allocation;
  final RpcResponderEndpoint endpoint;
  final RpcTurnRelayResponderTransport transport;

  Future<void> dispose() async {
    allocation.close();
    await transport.close();
    await endpoint.close();
  }
}

