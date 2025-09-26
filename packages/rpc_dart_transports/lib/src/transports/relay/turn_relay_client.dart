// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'turn_message.dart';

/// Simple TURN relay client that performs Allocate/Refresh/CreatePermission
/// flows against [TurnRelayServer] and exposes relayed payloads as a byte
/// stream.
final class TurnRelayClient {
  TurnRelayClient._({
    required RawDatagramSocket socket,
    required this.serverAddress,
    required this.serverPort,
    required this.requestTimeout,
    required this.allocationRefreshMargin,
    required this.permissionLifetime,
    required this.permissionRefreshMargin,
    required this.autoCreatePermission,
  }) : _socket = socket,
        _inboundController = StreamController<Uint8List>.broadcast();

  /// Establishes a TURN allocation against [serverAddress]/[serverPort] and
  /// returns an active [TurnRelayClient].
  static Future<TurnRelayClient> connect({
    required InternetAddress serverAddress,
    required int serverPort,
    InternetAddress? localAddress,
    int localPort = 0,
    Duration requestTimeout = const Duration(seconds: 5),
    Duration? requestedAllocationLifetime,
    Duration allocationRefreshMargin = const Duration(seconds: 30),
    Duration permissionLifetime = const Duration(minutes: 5),
    Duration permissionRefreshMargin = const Duration(seconds: 30),
    bool autoCreatePermission = true,
  }) async {
    final socket = await RawDatagramSocket.bind(
      localAddress ?? InternetAddress.anyIPv4,
      localPort,
    );
    socket.readEventsEnabled = true;
    socket.writeEventsEnabled = true;

    final client = TurnRelayClient._(
      socket: socket,
      serverAddress: serverAddress,
      serverPort: serverPort,
      requestTimeout: requestTimeout,
      allocationRefreshMargin: allocationRefreshMargin,
      permissionLifetime: permissionLifetime,
      permissionRefreshMargin: permissionRefreshMargin,
      autoCreatePermission: autoCreatePermission,
    );

    try {
      await client._initialize(requestedAllocationLifetime);
      return client;
    } catch (error) {
      await client.close();
      rethrow;
    }
  }

  /// TURN server address.
  final InternetAddress serverAddress;

  /// TURN server port.
  final int serverPort;

  /// Timeout used for Allocate/Refresh/CreatePermission requests.
  final Duration requestTimeout;

  /// Margin used when scheduling allocation refreshes.
  final Duration allocationRefreshMargin;

  /// Expected permission lifetime used for refresh scheduling.
  final Duration permissionLifetime;

  /// Margin before [permissionLifetime] when the client reissues CreatePermission.
  final Duration permissionRefreshMargin;

  /// When enabled, [send] automatically creates peer permissions if required.
  final bool autoCreatePermission;

  final RawDatagramSocket _socket;
  final StreamController<Uint8List> _inboundController;

  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _refreshTimer;
  final Map<String, Timer> _permissionTimers = {};
  final Map<String, Completer<TurnMessage>> _pendingRequests = {};
  final Set<String> _permissions = <String>{};

  late InternetAddress _relayedAddress;
  late int _relayedPort;
  Duration _allocationLifetime = const Duration(minutes: 10);
  bool _closed = false;

  /// Stream of payloads received from peers via the relay.
  Stream<Uint8List> get bytes => _inboundController.stream;

  /// Address advertised via XOR-RELAYED-ADDRESS for this allocation.
  InternetAddress get relayedAddress => _relayedAddress;

  /// Port advertised via XOR-RELAYED-ADDRESS for this allocation.
  int get relayedPort => _relayedPort;

  /// Whether the client has been closed.
  bool get isClosed => _closed;

  Future<void> _initialize(Duration? requestedAllocationLifetime) async {
    _subscription = _socket.listen(
      _handleSocketEvent,
      onError: (Object error, StackTrace stackTrace) {
        if (!_inboundController.isClosed) {
          _inboundController.addError(error, stackTrace);
        }
      },
      onDone: () {
        if (!_closed) {
          unawaited(close());
        }
      },
      cancelOnError: false,
    );

    await _performAllocate(requestedAllocationLifetime);
  }

  Future<void> _performAllocate(Duration? requestedAllocationLifetime) async {
    final transactionId = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.requestedTransport,
        _encodeRequestedTransport(TurnRequestedTransport.udp),
      ),
      if (requestedAllocationLifetime != null)
        TurnAttribute(
          TurnAttributeType.lifetime,
          encodeLifetime(requestedAllocationLifetime),
        ),
    ];

    final request = TurnMessage(
      method: TurnMethod.allocate,
      messageClass: TurnMessageClass.request,
      transactionId: transactionId,
      attributes: attributes,
    );

    final response = await _sendRequest(request);

    final relayedAttr =
        response.firstAttribute(TurnAttributeType.xorRelayedAddress);
    if (relayedAttr == null) {
      throw const TurnRelayException('Allocate success without relayed address');
    }

    final (address, port) = decodeXorAddress(relayedAttr, response.transactionId);
    _relayedAddress = address;
    _relayedPort = port;

    final lifetimeAttr = response.firstAttribute(TurnAttributeType.lifetime);
    if (lifetimeAttr != null) {
      _allocationLifetime = decodeLifetime(lifetimeAttr);
    }

    _scheduleRefresh();
  }

  /// Sends a CreatePermission request for [peerAddress]/[peerPort].
  Future<void> addPermission(
    InternetAddress peerAddress,
    int peerPort,
  ) async {
    _ensureOpen();
    await _createPermission(peerAddress, peerPort);
  }

  /// Sends payload bytes towards a peer through the relay.
  Future<void> send(
    Uint8List payload, {
    required InternetAddress peerAddress,
    required int peerPort,
  }) async {
    _ensureOpen();

    final key = _permissionKey(peerAddress, peerPort);
    if (!_permissions.contains(key)) {
      if (!autoCreatePermission) {
        throw StateError(
          'Permission for ${peerAddress.address}:$peerPort is not established',
        );
      }
      await _createPermission(peerAddress, peerPort);
    }

    final tx = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorPeerAddress,
        encodeXorAddress(peerAddress, peerPort, tx),
      ),
      TurnAttribute(TurnAttributeType.data, encodeData(payload)),
    ];

    final indication = TurnMessage(
      method: TurnMethod.send,
      messageClass: TurnMessageClass.indication,
      transactionId: tx,
      attributes: attributes,
    );

    _socket.send(indication.encode(), serverAddress, serverPort);
  }

  Future<void> _createPermission(
    InternetAddress peerAddress,
    int peerPort,
  ) async {
    final tx = TurnMessage.generateTransactionId();
    final request = TurnMessage(
      method: TurnMethod.createPermission,
      messageClass: TurnMessageClass.request,
      transactionId: tx,
      attributes: [
        TurnAttribute(
          TurnAttributeType.xorPeerAddress,
          encodeXorAddress(peerAddress, peerPort, tx),
        ),
      ],
    );

    await _sendRequest(request);

    final key = _permissionKey(peerAddress, peerPort);
    _permissions.add(key);
    _schedulePermissionRefresh(key, peerAddress, peerPort);
  }

  void _scheduleRefresh() {
    final lifetimeMicros = _allocationLifetime.inMicroseconds;
    if (lifetimeMicros <= 0) {
      return;
    }

    var marginMicros = allocationRefreshMargin.inMicroseconds;
    if (marginMicros >= lifetimeMicros) {
      marginMicros = lifetimeMicros ~/ 2;
    }

    final delayMicros = lifetimeMicros - marginMicros;

    _refreshTimer?.cancel();
    final clampedMicros = delayMicros.clamp(0, lifetimeMicros) as int;

    _refreshTimer = Timer(
      Duration(microseconds: clampedMicros),
      _refreshAllocation,
    );
  }

  Future<void> _refreshAllocation() async {
    if (_closed) {
      return;
    }

    final request = TurnMessage(
      method: TurnMethod.refresh,
      messageClass: TurnMessageClass.request,
    );

    try {
      final response = await _sendRequest(request);
      final lifetimeAttr = response.firstAttribute(TurnAttributeType.lifetime);
      if (lifetimeAttr != null) {
        _allocationLifetime = decodeLifetime(lifetimeAttr);
      }
    } on Object {
      // Ignore refresh errors; allocation will eventually expire.
      return;
    }

    _scheduleRefresh();
  }

  void _schedulePermissionRefresh(
    String key,
    InternetAddress address,
    int port,
  ) {
    final lifetimeMicros = permissionLifetime.inMicroseconds;
    if (lifetimeMicros <= 0) {
      return;
    }

    var marginMicros = permissionRefreshMargin.inMicroseconds;
    if (marginMicros >= lifetimeMicros) {
      marginMicros = lifetimeMicros ~/ 2;
    }

    final delayMicros = lifetimeMicros - marginMicros;

    _permissionTimers[key]?.cancel();
    final clampedMicros = delayMicros.clamp(0, lifetimeMicros) as int;

    _permissionTimers[key] = Timer(
      Duration(microseconds: clampedMicros),
      () async {
        if (_closed) {
          return;
        }
        try {
          await _createPermission(address, port);
        } catch (_) {
          // Best effort; failures will be surfaced on explicit send attempts.
        }
      },
    );
  }

  void _handleSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }

    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      final data = Uint8List.fromList(datagram!.data);
      if (data.isEmpty) {
        continue;
      }

      if (_isChannelData(data)) {
        final payload = _decodeChannelData(data);
        if (payload != null) {
          _inboundController.add(payload);
        }
        continue;
      }

      final message = TurnMessage.decode(data);
      if (message == null) {
        continue;
      }

      switch (message.messageClass) {
        case TurnMessageClass.successResponse:
          _resolveRequest(message.transactionId, message);
          break;
        case TurnMessageClass.errorResponse:
          _failRequest(message);
          break;
        case TurnMessageClass.indication:
          _handleIndication(message);
          break;
        case TurnMessageClass.request:
          break;
      }
    }
  }

  void _handleIndication(TurnMessage message) {
    if (message.method != TurnMethod.data) {
      return;
    }

    final dataAttr = message.firstAttribute(TurnAttributeType.data);
    if (dataAttr == null) {
      return;
    }

    _inboundController.add(Uint8List.fromList(dataAttr));
  }

  void _resolveRequest(Uint8List transactionId, TurnMessage message) {
    final key = _transactionKey(transactionId);
    final completer = _pendingRequests.remove(key);
    completer?.complete(message);
  }

  void _failRequest(TurnMessage message) {
    final key = _transactionKey(message.transactionId);
    final completer = _pendingRequests.remove(key);
    if (completer == null) {
      return;
    }

    final errorAttr = message.firstAttribute(TurnAttributeType.errorCode);
    if (errorAttr == null || errorAttr.length < 4) {
      completer.completeError(const TurnRelayException('TURN error response'));
      return;
    }

    final view = ByteData.sublistView(errorAttr);
    final code = view.getUint8(2) * 100 + view.getUint8(3);
    final reasonBytes = errorAttr.length > 4
        ? errorAttr.sublist(4)
        : Uint8List(0);
    final reason = utf8.decode(reasonBytes, allowMalformed: true);
    completer.completeError(
      TurnRelayException('TURN request failed: $reason', code: code),
    );
  }

  Future<TurnMessage> _sendRequest(TurnMessage request) {
    final key = _transactionKey(request.transactionId);
    final completer = Completer<TurnMessage>();
    _pendingRequests[key] = completer;

    _socket.send(request.encode(), serverAddress, serverPort);

    final timer = Timer(requestTimeout, () {
      final pending = _pendingRequests.remove(key);
      if (pending == null || pending.isCompleted) {
        return;
      }
      pending.completeError(
        const TurnRelayException('TURN request timed out'),
      );
    });

    return completer.future.whenComplete(timer.cancel);
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    for (final timer in _permissionTimers.values) {
      timer.cancel();
    }
    _permissionTimers.clear();
    _refreshTimer?.cancel();
    _refreshTimer = null;

    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const TurnRelayException('Client closed before response'),
        );
      }
    }
    _pendingRequests.clear();

    await _subscription?.cancel();
    _subscription = null;

    _socket.close();

    await _inboundController.close();
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('TURN relay client is closed');
    }
  }

  static String _transactionKey(Uint8List transactionId) =>
      base64Encode(transactionId);

  static String _permissionKey(InternetAddress address, int port) =>
      '${address.address}:$port';

  static bool _isChannelData(Uint8List data) =>
      data.length >= 4 && (data[0] & 0xC0) == 0x40;

  static Uint8List? _decodeChannelData(Uint8List data) {
    if (data.length < 4) {
      return null;
    }
    final header = ByteData.sublistView(data, 0, 4);
    final length = header.getUint16(2);
    if (length > data.length - 4) {
      return null;
    }
    return Uint8List.fromList(data.sublist(4, 4 + length));
  }

  static Uint8List _encodeRequestedTransport(int protocolNumber) {
    final data = Uint8List(4);
    data[0] = protocolNumber;
    return data;
  }
}

/// Error thrown for TURN relay client failures.
class TurnRelayException implements Exception {
  const TurnRelayException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() =>
      code != null ? 'TurnRelayException($code): $message' : 'TurnRelayException: $message';
}
