import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

/// Helper that creates a TURN relay allocation and later attaches peer
/// transports once the remote endpoint is known.
class RpcTurnRelayPeer {
  final TurnRelayClient _client;
  final List<RpcResponderContract> _pendingContracts;
  RpcTurnRelayCallerTransport? _callerTransport;
  RpcTurnRelayResponderTransport? _responderTransport;
  RpcCallerEndpoint? _callerEndpoint;
  RpcResponderEndpoint? _responderEndpoint;

  /// Address used by remote peers when dialing this client through the relay.
  InternetAddress get relayAddress => _client.relayAddress;
  /// Port advertised to peers for the relay allocation.
  int get relayPort => _client.relayPort;

  /// Notifications about remote peers requesting a connection.
  Stream<TurnConnectRequest> get connectRequests => _client.connectRequests;

  /// Caller endpoint used for outgoing RPC invocations after [connectPeer].
  RpcCallerEndpoint get callerEndpoint {
    final endpoint = _callerEndpoint;
    if (endpoint == null) {
      throw StateError('Peer not connected yet');
    }
    return endpoint;
  }

  /// Responder endpoint that receives inbound RPC calls after [connectPeer].
  RpcResponderEndpoint get responderEndpoint {
    final endpoint = _responderEndpoint;
    if (endpoint == null) {
      throw StateError('Peer not connected yet');
    }
    return endpoint;
  }

  RpcTurnRelayPeer._(this._client, this._pendingContracts);

  /// Connects to the TURN relay and stores responder contracts for later
  /// registration.
  static Future<RpcTurnRelayPeer> connectToRelay({
    required InternetAddress serverAddress,
    required int serverPort,
    Iterable<RpcResponderContract> responderContracts = const [],
    TurnRelayClientOptions options = const TurnRelayClientOptions(),
  }) async {
    final client = await TurnRelayClient.connect(
      serverAddress: serverAddress,
      serverPort: serverPort,
      options: options,
    );
    return RpcTurnRelayPeer._(client, List.of(responderContracts));
  }

  /// Creates transports towards [peerAddress]/[peerPort] and registers stored
  /// responder contracts.
  Future<void> connectPeer({
    required InternetAddress peerAddress,
    required int peerPort,
    RpcLogger? logger,
  }) async {
    // Create transports while reusing the same TurnRelayClient instance so the
    // relay allocation is not duplicated.
    _responderTransport ??= RpcTurnRelayResponderTransport.fromClient(
      client: _client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      logger: logger,
    );
    _callerTransport ??= RpcTurnRelayCallerTransport.fromClient(
      client: _client,
      peerAddress: peerAddress,
      peerPort: peerPort,
      logger: logger,
    );

    // Spin up the responder endpoint and register the buffered contracts.
    if (_responderEndpoint == null) {
      final responder = RpcResponderEndpoint(
        transport: _responderTransport!,
        debugLabel: 'turn-responder',
      );
      for (final contract in _pendingContracts) {
        responder.registerServiceContract(contract);
      }
      responder.start();
      _responderEndpoint = responder;
    }

    // Prepare the caller endpoint.
    _callerEndpoint ??= RpcCallerEndpoint(
      transport: _callerTransport!,
      debugLabel: 'turn-caller',
    );
  }

  /// Sends a Connect request so the relay notifies the remote peer about the
  /// desired connection.
  Future<void> sendConnectionInfoToPeer({
    required InternetAddress peerAddress,
    required int peerPort,
    Uint8List? payload,
  }) {
    return _client.requestPeerConnection(
      peerAddress: peerAddress,
      peerPort: peerPort,
      payload: payload,
    );
  }

  /// Registers the current allocation in the relay discovery catalogue.
  Future<void> registerService({
    required String serviceId,
    String? description,
  }) {
    return _client.registerService(
      serviceId: serviceId,
      description: description,
    );
  }

  /// Returns services registered in the discovery catalogue.
  Future<List<TurnRelayServiceInfo>> listServices({String? serviceId}) {
    return _client.listServices(serviceId: serviceId);
  }

  /// Releases transports and closes the TURN client.
  Future<void> close() async {
    await _callerEndpoint?.close();
    await _responderEndpoint?.close();
    await _callerTransport?.close();
    await _responderTransport?.close();
    await _client.close();
  }
}
