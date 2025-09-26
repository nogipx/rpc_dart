// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_io/io.dart';

import 'turn_message.dart';
import 'turn_tcp_frame.dart';

/// Options used to customize [TurnRelayClient.connect].
class TurnRelayClientOptions {
  const TurnRelayClientOptions({
    this.localAddress,
    this.localPort = 0,
    this.requestTimeout = const Duration(seconds: 5),
    this.requestedAllocationLifetime,
    this.allocationRefreshMargin = const Duration(seconds: 30),
    this.permissionLifetime = const Duration(minutes: 5),
    this.permissionRefreshMargin = const Duration(seconds: 30),
    this.autoCreatePermission = true,
    this.requestedTransport = TurnRequestedTransport.udp,
  });

  /// Local interface bound by the TCP socket (defaults to ANY).
  final InternetAddress? localAddress;

  /// Local TCP port (0 lets the OS pick an ephemeral port).
  final int localPort;

  /// Timeout used for Allocate/Refresh/CreatePermission requests.
  final Duration requestTimeout;

  /// Client-requested allocation lifetime advertised in Allocate requests.
  final Duration? requestedAllocationLifetime;

  /// Margin used when scheduling allocation refreshes.
  final Duration allocationRefreshMargin;

  /// Expected permission lifetime used for refresh scheduling.
  final Duration permissionLifetime;

  /// Margin before [permissionLifetime] when the client refreshes permissions.
  final Duration permissionRefreshMargin;

  /// When enabled, [TurnRelayClient.send] auto-creates missing permissions.
  final bool autoCreatePermission;

  /// IP protocol advertised via the REQUESTED-TRANSPORT attribute.
  final int requestedTransport;
}

/// Simple TURN relay client that performs Allocate/Refresh/CreatePermission
/// flows against [TurnRelayServer] and exposes relayed payloads as a byte
/// stream.
final class TurnRelayClient {
  TurnRelayClient._({
    required Socket socket,
    required this.serverAddress,
    required this.serverPort,
    required TurnRelayClientOptions options,
  })  : requestTimeout = options.requestTimeout,
        allocationRefreshMargin = options.allocationRefreshMargin,
        permissionLifetime = options.permissionLifetime,
        permissionRefreshMargin = options.permissionRefreshMargin,
        autoCreatePermission = options.autoCreatePermission,
        requestedTransport = options.requestedTransport,
        _socket = socket,
        _inboundController = StreamController<Uint8List>.broadcast(),
        _connectRequestController =
            StreamController<TurnConnectRequest>.broadcast();

  /// Establishes a TURN allocation against [serverAddress]/[serverPort] and
  /// returns an active [TurnRelayClient].
  static Future<TurnRelayClient> connect({
    required InternetAddress serverAddress,
    required int serverPort,
    TurnRelayClientOptions options = const TurnRelayClientOptions(),
  }) async {
    final socket = await Socket.connect(
      serverAddress,
      serverPort,
      sourceAddress: options.localAddress,
      sourcePort: options.localPort,
    );

    final client = TurnRelayClient._(
      socket: socket,
      serverAddress: serverAddress,
      serverPort: serverPort,
      options: options,
    );

    try {
      await client._initialize(options.requestedAllocationLifetime);
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

  /// IP protocol requested during Allocate.
  final int requestedTransport;

  final Socket _socket;
  final StreamController<Uint8List> _inboundController;
  final StreamController<TurnConnectRequest> _connectRequestController;
  late final TurnTcpFrameDecoder _frameDecoder;

  StreamSubscription<Uint8List>? _subscription;
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

  /// Stream of peer connection requests delivered by the relay.
  Stream<TurnConnectRequest> get connectRequests =>
      _connectRequestController.stream;

  /// Address advertised via XOR-RELAYED-ADDRESS for this allocation.
  InternetAddress get relayAddress => _relayedAddress;

  /// Port advertised via XOR-RELAYED-ADDRESS for this allocation.
  int get relayPort => _relayedPort;

  /// Whether the client has been closed.
  bool get isClosed => _closed;

  Future<void> _initialize(Duration? requestedAllocationLifetime) async {
    _frameDecoder = TurnTcpFrameDecoder(
      onTurnMessage: _handleTurnMessage,
      onChannelData: (_, payload) {
        _inboundController.add(payload);
      },
    );

    _subscription = _socket.listen(
      (Uint8List data) {
        if (data.isNotEmpty) {
          _frameDecoder.addChunk(data);
        }
      },
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
        _encodeRequestedTransport(requestedTransport),
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
      throw const TurnRelayException(
          'Allocate success without relayed address');
    }

    final (address, port) =
        decodeXorAddress(relayedAttr, response.transactionId);
    _relayedAddress = address;
    _relayedPort = port;

    final lifetimeAttr = response.firstAttribute(TurnAttributeType.lifetime);
    if (lifetimeAttr != null) {
      _allocationLifetime = decodeLifetime(lifetimeAttr);
    }

    _scheduleRefresh();
  }

  /// Sends a custom TURN request that asks the relay to notify [peerAddress]
  /// / [peerPort] about the current allocation.
  Future<void> requestPeerConnection({
    required InternetAddress peerAddress,
    required int peerPort,
    Uint8List? payload,
  }) async {
    _ensureOpen();

    final transactionId = TurnMessage.generateTransactionId();
    final attributes = <TurnAttribute>[
      TurnAttribute(
        TurnAttributeType.xorPeerAddress,
        encodeXorAddress(peerAddress, peerPort, transactionId),
      ),
      if (payload != null)
        TurnAttribute(TurnAttributeType.data, encodeData(payload)),
    ];

    final request = TurnMessage(
      method: TurnMethod.connectRequest,
      messageClass: TurnMessageClass.request,
      transactionId: transactionId,
      attributes: attributes,
    );

    await _sendRequest(request);
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

    _socket.add(indication.encode());
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

  void _handleTurnMessage(TurnMessage message) {
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

  void _handleIndication(TurnMessage message) {
    switch (message.method) {
      case TurnMethod.data:
        final dataAttr = message.firstAttribute(TurnAttributeType.data);
        if (dataAttr == null) {
          return;
        }
        _inboundController.add(Uint8List.fromList(dataAttr));
        break;
      case TurnMethod.connectRequest:
        _handleConnectRequestIndication(message);
        break;
      default:
        break;
    }
  }

  void _handleConnectRequestIndication(TurnMessage message) {
    final peerAttr = message.firstAttribute(TurnAttributeType.xorPeerAddress);
    if (peerAttr == null) {
      return;
    }

    final (peerAddress, peerPort) =
        decodeXorAddress(peerAttr, message.transactionId);
    final payloadAttr = message.firstAttribute(TurnAttributeType.data);
    _connectRequestController.add(
      TurnConnectRequest(
        peerAddress: peerAddress,
        peerPort: peerPort,
        payload: payloadAttr != null ? Uint8List.fromList(payloadAttr) : null,
      ),
    );
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
    final reasonBytes =
        errorAttr.length > 4 ? errorAttr.sublist(4) : Uint8List(0);
    final reason = utf8.decode(reasonBytes, allowMalformed: true);
    completer.completeError(
      TurnRelayException('TURN request failed: $reason', code: code),
    );
  }

  Future<TurnMessage> _sendRequest(TurnMessage request) {
    final key = _transactionKey(request.transactionId);
    final completer = Completer<TurnMessage>();
    _pendingRequests[key] = completer;

    _socket.add(request.encode());

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

    await _socket.close();

    await _inboundController.close();
    await _connectRequestController.close();
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
  String toString() => code != null
      ? 'TurnRelayException($code): $message'
      : 'TurnRelayException: $message';
}

/// Payload delivered when another allocation asks to establish a connection.
class TurnConnectRequest {
  TurnConnectRequest({
    required this.peerAddress,
    required this.peerPort,
    this.payload,
  });

  final InternetAddress peerAddress;
  final int peerPort;
  final Uint8List? payload;
}
