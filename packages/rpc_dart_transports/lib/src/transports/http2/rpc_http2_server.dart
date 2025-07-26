// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';

import '../../server/rpc_server_interface.dart';
import 'rpc_http2_responder_transport.dart';

/// Высокоуровневый HTTP/2 RPC сервер
///
/// Инкапсулирует создание HTTP/2 сервера и автоматическую настройку транспортов.
/// Для каждого нового подключения создает отдельный RpcResponderEndpoint.
class RpcHttp2Server implements IRpcServer {
  final String _host;
  final int _port;
  final RpcLogger? _logger;
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(Socket socket)? _onConnectionOpened;
  final void Function(Socket socket)? _onConnectionClosed;

  ServerSocket? _serverSocket;
  bool _isRunning = false;
  final List<StreamSubscription> _subscriptions = [];
  final List<RpcResponderEndpoint> _endpoints = [];

  /// Создает HTTP/2 RPC сервер
  ///
  /// [host] - хост для привязки (по умолчанию 'localhost')
  /// [port] - порт для привязки
  /// [logger] - логгер для отладки
  /// [onEndpointCreated] - вызывается при создании нового RPC endpoint'а
  /// [onConnectionError] - вызывается при ошибке соединения
  /// [onConnectionOpened] - вызывается при открытии нового соединения
  /// [onConnectionClosed] - вызывается при закрытии соединения
  RpcHttp2Server({
    String host = 'localhost',
    required int port,
    RpcLogger? logger,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(Socket socket)? onConnectionOpened,
    void Function(Socket socket)? onConnectionClosed,
  })  : _host = host,
        _port = port,
        _logger = logger?.child('Http2Server'),
        _onEndpointCreated = onEndpointCreated,
        _onConnectionError = onConnectionError,
        _onConnectionOpened = onConnectionOpened,
        _onConnectionClosed = onConnectionClosed;

  /// Создает простой HTTP/2 сервер с автоматической регистрацией контрактов
  ///
  /// [port] - порт для привязки
  /// [contracts] - список контрактов для регистрации на каждом endpoint'е
  /// [host] - хост для привязки (по умолчанию 'localhost')
  /// [logger] - логгер для отладки
  factory RpcHttp2Server.createWithContracts({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcHttp2Server(
      host: host,
      port: port,
      logger: logger,
      onEndpointCreated: (endpoint) {
        logger?.debug(
            'Регистрация ${contracts.length} контрактов на новом endpoint');
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
          logger?.debug('Зарегистрирован контракт: ${contract.serviceName}');
        }
      },
      onConnectionError: (error, stackTrace) {
        logger?.error('Ошибка соединения HTTP/2',
            error: error, stackTrace: stackTrace);
      },
    );
  }

  /// Хост сервера
  @override
  String get host => _host;

  /// Порт сервера
  @override
  int get port => _port;

  /// Активные endpoints
  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  /// Запущен ли сервер
  @override
  bool get isRunning => _isRunning;

  /// Запускает HTTP/2 сервер
  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger?.warning('HTTP/2 сервер уже запущен');
      return;
    }

    _logger?.info('Запуск HTTP/2 сервера на $_host:$_port');

    try {
      _serverSocket = await ServerSocket.bind(_host, _port);
      _isRunning = true;

      _logger?.info('HTTP/2 сервер запущен на $_host:$_port');

      // Слушаем входящие соединения
      final subscription = _serverSocket!.listen(
        _handleConnection,
        onError: (error, stackTrace) {
          _logger?.error('Ошибка сервера',
              error: error, stackTrace: stackTrace);
          _onConnectionError?.call(error, stackTrace);
        },
      );

      _subscriptions.add(subscription);
    } catch (e, stackTrace) {
      _logger?.error('Не удалось запустить HTTP/2 сервер',
          error: e, stackTrace: stackTrace);
      _isRunning = false;
      rethrow;
    }
  }

  /// Останавливает HTTP/2 сервер
  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _logger?.info('Остановка HTTP/2 сервера');
    _isRunning = false;

    // Отменяем все подписки
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    // Закрываем все endpoints
    for (final endpoint in _endpoints) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Ошибка при закрытии endpoint: $e');
      }
    }
    _endpoints.clear();

    // Закрываем серверный сокет
    await _serverSocket?.close();
    _serverSocket = null;

    _logger?.info('HTTP/2 сервер остановлен');
  }

  /// Обрабатывает новое HTTP/2 соединение
  void _handleConnection(Socket socket) {
    final clientAddress = '${socket.remoteAddress}:${socket.remotePort}';
    _logger?.debug('Новое HTTP/2 подключение от $clientAddress');

    _onConnectionOpened?.call(socket);

    try {
      // Создаем HTTP/2 соединение
      final connection = http2.ServerTransportConnection.viaSocket(socket);

      // Создаем серверный транспорт (правильный способ!)
      final serverTransport = RpcHttp2ResponderTransport(
        connection: connection,
        logger: _logger,
      );

      // Создаем RPC endpoint
      final endpoint = RpcResponderEndpoint(
        transport: serverTransport,
        debugLabel: 'Http2Endpoint-$clientAddress',
        loggerColors: RpcLoggerColors.singleColor(AnsiColor.cyan),
      );

      _endpoints.add(endpoint);

      // Уведомляем о создании endpoint'а
      _onEndpointCreated?.call(endpoint);

      // Запускаем endpoint
      endpoint.start();

      _logger?.debug('RPC endpoint создан для $clientAddress');

      // Обрабатываем закрытие соединения
      socket.done.then((_) {
        _logger?.debug('HTTP/2 соединение $clientAddress закрыто');
        _endpoints.remove(endpoint);
        _onConnectionClosed?.call(socket);
      }).catchError((error) {
        _logger
            ?.warning('Ошибка при закрытии соединения $clientAddress: $error');
        _endpoints.remove(endpoint);
        _onConnectionClosed?.call(socket);
      });
    } catch (e, stackTrace) {
      _logger?.error('Ошибка при создании HTTP/2 RPC соединения',
          error: e, stackTrace: stackTrace);
      _onConnectionError?.call(e, stackTrace);
      socket.destroy();
    }
  }
}

/// Фабрика для создания HTTP/2 RPC серверов
class RpcHttp2ServerFactory implements IRpcServerFactory {
  const RpcHttp2ServerFactory();

  @override
  IRpcServer create({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcHttp2Server.createWithContracts(
      port: port,
      contracts: contracts,
      host: host,
      logger: logger,
    );
  }

  @override
  String get transportType => 'HTTP/2';
}
