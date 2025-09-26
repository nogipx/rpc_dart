import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:universal_io/io.dart';

/// Позволяет подключиться к TURN‑relay, а затем позднее задать адрес пира.
class RpcTurnRelayPeer {
  final TurnRelayClient _client;
  final List<RpcResponderContract> _pendingContracts;
  RpcTurnRelayCallerTransport? _callerTransport;
  RpcTurnRelayResponderTransport? _responderTransport;
  RpcCallerEndpoint? _callerEndpoint;
  RpcResponderEndpoint? _responderEndpoint;

  /// Адрес, по которому другие клиенты должны подключаться к вашему пиру.
  InternetAddress get relayAddress => _client.relayAddress;
  int get relayPort => _client.relayPort;

  /// Уведомления о том, что другой участник хочет подключиться к нам.
  Stream<TurnConnectRequest> get connectRequests => _client.connectRequests;

  /// Endpoint для исходящих вызовов (доступен после `connectPeer()`).
  RpcCallerEndpoint get callerEndpoint {
    final endpoint = _callerEndpoint;
    if (endpoint == null) {
      throw StateError('Peer not connected yet');
    }
    return endpoint;
  }

  /// Endpoint для приёма входящих вызовов (создаётся после `connectPeer()`).
  RpcResponderEndpoint get responderEndpoint {
    final endpoint = _responderEndpoint;
    if (endpoint == null) {
      throw StateError('Peer not connected yet');
    }
    return endpoint;
  }

  RpcTurnRelayPeer._(this._client, this._pendingContracts);

  /// Подключается к TURN‑relay и хранит контракты для последующей регистрации.
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

  /// После обмена `relayAddress`/`relayPort` с другим участником вызывайте этот метод.
  Future<void> connectPeer({
    required InternetAddress peerAddress,
    required int peerPort,
    RpcLogger? logger,
  }) async {
    // Создаём транспорты. Здесь используют один и тот же TurnRelayClient,
    // поэтому соединение с relay не дублируется.
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

    // Поднимаем responder‑endpoint и регистрируем сохранённые контракты.
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

    // Поднимаем caller‑endpoint.
    _callerEndpoint ??= RpcCallerEndpoint(
      transport: _callerTransport!,
      debugLabel: 'turn-caller',
    );
  }

  /// Отправляет на relay запрос, чтобы оно уведомило удалённого пира о желании
  /// подключиться.
  Future<void> requestPeerConnection({
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

  /// Закрывает все ресурсы.
  Future<void> close() async {
    await _callerEndpoint?.close();
    await _responderEndpoint?.close();
    await _callerTransport?.close();
    await _responderTransport?.close();
    await _client.close();
  }
}
