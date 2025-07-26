// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

/// Высокоуровневый WebSocket RPC сервер
///
/// Инкапсулирует создание WebSocket сервера и автоматическую настройку транспортов.
/// Для каждого нового WebSocket подключения создает отдельный RpcResponderEndpoint.
class RpcWebSocketServer implements IRpcServer {
  final String _host;
  final int _port;
  final RpcLogger? _logger;
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(WebSocketChannel channel)? _onConnectionOpened;
  final void Function(WebSocketChannel channel)? _onConnectionClosed;

  HttpServer? _httpServer;
  bool _isRunning = false;
  final List<RpcResponderEndpoint> _endpoints = [];

  /// Создает WebSocket RPC сервер
  ///
  /// [host] - хост для привязки (по умолчанию 'localhost')
  /// [port] - порт для привязки
  /// [logger] - логгер для отладки
  /// [onEndpointCreated] - вызывается при создании нового RPC endpoint'а
  /// [onConnectionError] - вызывается при ошибке соединения
  /// [onConnectionOpened] - вызывается при открытии нового соединения
  /// [onConnectionClosed] - вызывается при закрытии соединения
  RpcWebSocketServer({
    String host = 'localhost',
    required int port,
    RpcLogger? logger,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(WebSocketChannel channel)? onConnectionOpened,
    void Function(WebSocketChannel channel)? onConnectionClosed,
  })  : _host = host,
        _port = port,
        _logger = logger?.child('WebSocketServer'),
        _onEndpointCreated = onEndpointCreated,
        _onConnectionError = onConnectionError,
        _onConnectionOpened = onConnectionOpened,
        _onConnectionClosed = onConnectionClosed;

  /// Создает простой WebSocket сервер с автоматической регистрацией контрактов
  ///
  /// [port] - порт для привязки
  /// [contracts] - список контрактов для регистрации на каждом endpoint'е
  /// [host] - хост для привязки (по умолчанию 'localhost')
  /// [logger] - логгер для отладки
  factory RpcWebSocketServer.createWithContracts({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer(
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

    _logger?.info('Запуск WebSocket сервера на $_host:$_port');

    try {
      // Создаем HTTP сервер для WebSocket upgrade
      _httpServer = await HttpServer.bind(_host, _port);
      _isRunning = true;

      // Обрабатываем входящие HTTP запросы для WebSocket upgrade
      _httpServer!.listen(_handleHttpRequest, onError: (error, stackTrace) {
        _logger?.error('Ошибка WebSocket сервера',
            error: error, stackTrace: stackTrace);
        _onConnectionError?.call(error, stackTrace);
      });

      _logger?.info('WebSocket сервер запущен на $_host:$_port');
    } catch (e, stackTrace) {
      _logger?.error('Не удалось запустить WebSocket сервер',
          error: e, stackTrace: stackTrace);
      _isRunning = false;
      rethrow;
    }
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

    // Закрываем HTTP сервер
    await _httpServer?.close();
    _httpServer = null;

    _logger?.info('WebSocket сервер остановлен');
  }

  /// Обрабатывает HTTP запросы для WebSocket upgrade
  void _handleHttpRequest(HttpRequest request) {
    try {
      // Проверяем, что это WebSocket upgrade запрос
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        _handleWebSocketUpgrade(request);
      } else {
        // Отклоняем не-WebSocket запросы
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('WebSocket connection required');
        request.response.close();
      }
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при обработке HTTP запроса',
          error: e, stackTrace: stackTrace);
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.close();
    }
  }

  /// Обрабатывает WebSocket upgrade
  void _handleWebSocketUpgrade(HttpRequest request) async {
    try {
      // Выполняем WebSocket upgrade
      final webSocket = await WebSocketTransformer.upgrade(request);
      final channel = IOWebSocketChannel(webSocket);

      final clientAddress =
          '${request.connectionInfo?.remoteAddress}:${request.connectionInfo?.remotePort}';
      _logger?.debug('Новое WebSocket подключение от $clientAddress');

      _handleWebSocketConnection(channel, clientAddress);
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при WebSocket upgrade',
          error: e, stackTrace: stackTrace);
      _onConnectionError?.call(e, stackTrace);
    }
  }

  /// Обрабатывает новое WebSocket соединение
  void _handleWebSocketConnection(
      WebSocketChannel channel, String clientAddress) {
    _onConnectionOpened?.call(channel);

    try {
      // Создаем серверный транспорт для WebSocket
      final serverTransport = RpcWebSocketResponderTransport(
        channel,
        logger: _logger,
      );

      // Создаем RPC endpoint
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'WebSocketEndpoint-$clientAddress',
        loggerColors: RpcLoggerColors.singleColor(AnsiColor.magenta),
      );

      _endpoints.add(endpoint);

      // Уведомляем о создании endpoint'а
      _onEndpointCreated?.call(endpoint);

      // Запускаем endpoint
      endpoint.start();

      _logger?.debug(
          'RPC endpoint создан для WebSocket соединения $clientAddress');

      // Обрабатываем закрытие соединения
      channel.sink.done.then((_) {
        _logger?.debug('WebSocket соединение $clientAddress закрыто');
        _endpoints.remove(endpoint);
        _onConnectionClosed?.call(channel);
      }).catchError((error) {
        _logger?.warning(
            'Ошибка при закрытии WebSocket соединения $clientAddress: $error');
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
}

/// Фабрика для создания WebSocket RPC серверов
class RpcWebSocketServerFactory implements IRpcServerFactory {
  const RpcWebSocketServerFactory();

  @override
  IRpcServer create({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcWebSocketServer.createWithContracts(
      port: port,
      contracts: contracts,
      host: host,
      logger: logger,
    );
  }

  @override
  String get transportType => 'WebSocket';
}
