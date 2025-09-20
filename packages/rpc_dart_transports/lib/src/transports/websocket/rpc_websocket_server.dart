// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Высокоуровневый WebSocket RPC сервер БЕЗ использования dart:io
///
/// Сервер НЕ занимается сетевым биндингом и HTTP→WebSocket upgrade.
/// Он потребляет уже установленные WebSocket-подключения из переданного
/// потока [connections] и на каждое подключение поднимает RpcResponderEndpoint.
class RpcWebSocketServer implements IRpcServer {
  final String _host;
  final int _port;
  final RpcLogger? _logger;

  /// Поток входящих уже-открытых WebSocket-подключений.
  final Stream<WebSocketChannel> _connections;

  /// Коллбеки жизненного цикла
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(WebSocketChannel channel)? _onConnectionOpened;
  final void Function(WebSocketChannel channel)? _onConnectionClosed;

  StreamSubscription<WebSocketChannel>? _connectionsSub;
  bool _isRunning = false;
  final List<RpcResponderEndpoint> _endpoints = [];
  int _connCounter = 0;

  /// Создает WebSocket RPC сервер поверх [connections] (без io).
  ///
  /// [host]/[port] носят информативный характер (для логов/совместимости с интерфейсом),
  /// фактический сетевой листенер/апгрейд выполняется на стороне поставщика [connections].
  RpcWebSocketServer({
    required Stream<WebSocketChannel> connections,
    String host = 'localhost',
    required int port,
    RpcLogger? logger,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(WebSocketChannel channel)? onConnectionOpened,
    void Function(WebSocketChannel channel)? onConnectionClosed,
  })  : _connections = connections,
        _host = host,
        _port = port,
        _logger = logger?.child('WebSocketServer'),
        _onEndpointCreated = onEndpointCreated,
        _onConnectionError = onConnectionError,
        _onConnectionOpened = onConnectionOpened,
        _onConnectionClosed = onConnectionClosed;

  /// Упрощённая фабрика с автогенерацией эндпоинтов под контракты.
  ///
  /// ВАЖНО: здесь также требуется внешний поток [connections].
  factory RpcWebSocketServer.createWithContracts({
    required Stream<WebSocketChannel> connections,
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer(
      connections: connections,
      host: host,
      port: port,
      logger: logger,
      onEndpointCreated: (endpoint) {
        logger?.debug(
            'Регистрация ${contracts.length} контрактов на новом WebSocket endpoint');
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
          logger?.debug('Зарегистрирован контракт: ${contract.serviceName}');
        }
      },
      onConnectionError: (error, stackTrace) {
        logger?.error('Ошибка WebSocket соединения',
            error: error, stackTrace: stackTrace);
      },
    );
  }

  @override
  String get host => _host;

  @override
  int get port => _port;

  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  @override
  bool get isRunning => _isRunning;

  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger?.warning('WebSocket сервер уже запущен');
      return;
    }

    _logger?.info('Запуск WebSocket сервера (без io) на $_host:$_port');

    _isRunning = true;

    // Подписываемся на поток вновь пришедших WebSocket-подключений.
    _connectionsSub = _connections.listen(
      (WebSocketChannel channel) {
        final label = _nextPeerLabel();
        _logger?.debug('Новое WebSocket подключение: $label');
        _handleWebSocketConnection(channel, label);
      },
      onError: (Object error, StackTrace st) {
        _logger?.error('Ошибка потока подключений',
            error: error, stackTrace: st);
        _onConnectionError?.call(error, st);
      },
      onDone: () {
        _logger?.info('Поток подключений завершён');
        // Не останавливаем сервер автоматически: даём пользователю решать, когда вызывать stop().
      },
      cancelOnError: false,
    );

    _logger?.info('WebSocket сервер запущен (источник подключений активен)');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _logger?.info('Остановка WebSocket сервера');
    _isRunning = false;

    // Закрываем все endpoints
    for (final endpoint in _endpoints) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Ошибка при закрытии WebSocket endpoint: $e');
      }
    }
    _endpoints.clear();

    // Отписываемся от источника подключений
    try {
      await _connectionsSub?.cancel();
    } catch (e) {
      _logger?.warning('Ошибка при отмене подписки на подключения: $e');
    } finally {
      _connectionsSub = null;
    }

    _logger?.info('WebSocket сервер остановлен');
  }

  /// Обрабатывает новое WebSocket соединение (общая RPC-логика).
  void _handleWebSocketConnection(
      WebSocketChannel channel, String clientLabel) {
    _onConnectionOpened?.call(channel);

    try {
      // Серверный транспорт для WebSocket
      final serverTransport = RpcWebSocketResponderTransport(
        channel,
        logger: _logger,
      );

      // RPC endpoint
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'WebSocketEndpoint-$clientLabel',
        loggerColors: RpcLoggerColors.singleColor(AnsiColor.magenta),
      );

      _endpoints.add(endpoint);

      // Уведомляем о создании endpoint
      _onEndpointCreated?.call(endpoint);

      // Запускаем endpoint
      endpoint.start();

      _logger?.debug('RPC endpoint создан для соединения $clientLabel');

      // Закрытие соединения
      channel.sink.done.then((_) {
        _logger?.debug('WebSocket соединение $clientLabel закрыто');
        _endpoints.remove(endpoint);
        _onConnectionClosed?.call(channel);
      }).catchError((error) {
        _logger?.warning(
            'Ошибка при закрытии WebSocket соединения $clientLabel: $error');
        _endpoints.remove(endpoint);
        _onConnectionClosed?.call(channel);
      });
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при создании WebSocket RPC соединения',
          error: e, stackTrace: stackTrace);
      _onConnectionError?.call(e, stackTrace);
      channel.sink.close();
    }
  }

  String _nextPeerLabel() => 'peer-${++_connCounter}';
}

/// Фабрика для создания WebSocket RPC серверов (без io).
///
/// Поскольку в этом варианте сервер не биндится сам, фабрика
/// принимает поток [connections] в конструкторе и передает его в сервер.
class RpcWebSocketServerFactory implements IRpcServerFactory {
  final Stream<WebSocketChannel> connections;

  const RpcWebSocketServerFactory(this.connections);

  @override
  IRpcServer create({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer.createWithContracts(
      connections: connections,
      port: port,
      contracts: contracts,
      host: host,
      logger: logger,
    );
  }

  @override
  String get transportType => 'WebSocket';
}
