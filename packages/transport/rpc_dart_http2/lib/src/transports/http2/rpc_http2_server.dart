// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'rpc_http2_responder_transport.dart';

/// Высокоуровневый HTTP/2 RPC сервер
///
/// Инкапсулирует создание HTTP/2 сервера и автоматическую настройку транспортов.
/// Для каждого нового подключения создает отдельный RpcResponderEndpoint.
class RpcHttp2Server implements IRpcServer {
  final String _host;
  final int _port;
  final RpcSecurityPolicy _securityPolicy;
  final SecurityContext? _securityContext;
  final LogScope? _logger;
  final LogController? _logController;
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onConnectionError;
  final void Function(Socket socket)? _onConnectionOpened;
  final void Function(Socket socket)? _onConnectionClosed;
  final IRpcTransport Function(IRpcTransport inner, Socket socket)?
  _transportWrapper;

  // Plaintext (h2c) listener. Mutually exclusive with [_secureServerSocket].
  ServerSocket? _serverSocket;
  // TLS (h2) listener. Used when a SecurityContext is provided.
  SecureServerSocket? _secureServerSocket;
  bool _isRunning = false;

  /// Whether the server is serving over TLS (`true`) or plaintext h2c (`false`).
  bool get isSecure => _securityContext != null;
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
  /// [securityPolicy] - bounds per-stream message size, buffered bytes, and the
  ///   number of concurrent active streams per connection. Forwarded to every
  ///   [RpcHttp2ResponderTransport]. Defaults to `const RpcSecurityPolicy()`
  ///   so the built-in limits are enforced.
  /// [securityContext] - when non-null, the server binds a TLS socket
  ///   ([SecureServerSocket]) advertising ALPN `h2` instead of a plaintext
  ///   ([ServerSocket]) `h2c` socket. Provide a [SecurityContext] with a
  ///   certificate chain and private key to serve HTTP/2 over TLS. Defaults to
  ///   `null` (plaintext h2c) for backward compatibility.
  RpcHttp2Server({
    String host = 'localhost',
    required int port,
    RpcSecurityPolicy securityPolicy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
    LogController? logController,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onConnectionError,
    void Function(Socket socket)? onConnectionOpened,
    void Function(Socket socket)? onConnectionClosed,
    IRpcTransport Function(IRpcTransport inner, Socket socket)?
    transportWrapper,
  }) : _host = host,
       _port = port,
       _securityPolicy = securityPolicy,
       _securityContext = securityContext,
       _logger = logger?.child('Http2Server'),
       _logController = logController,
       _onEndpointCreated = onEndpointCreated,
       _onConnectionError = onConnectionError,
       _onConnectionOpened = onConnectionOpened,
       _onConnectionClosed = onConnectionClosed,
       _transportWrapper = transportWrapper;

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
    RpcSecurityPolicy securityPolicy = const RpcSecurityPolicy(),
    SecurityContext? securityContext,
    LogScope? logger,
  }) {
    return RpcHttp2Server(
      host: host,
      port: port,
      securityPolicy: securityPolicy,
      securityContext: securityContext,
      logger: logger,
      onEndpointCreated: (endpoint) {
        logger?.debug(
          'Регистрация ${contracts.length} контрактов на новом endpoint',
        );
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
          logger?.debug('Зарегистрирован контракт: ${contract.serviceName}');
        }
      },
      onConnectionError: (error, stackTrace) {
        logger?.error(
          'Ошибка соединения HTTP/2',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );
  }

  /// Хост сервера
  String get host => _host;

  /// Порт сервера
  ///
  /// Returns the OS-assigned port once bound when constructed with port `0`;
  /// otherwise the requested port.
  int get port => _serverSocket?.port ?? _secureServerSocket?.port ?? _port;

  /// Активные endpoints
  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  /// Drops a disconnected connection's endpoint and closes it.
  ///
  /// Closing is what used to be missing: the disconnect handler only removed
  /// the endpoint from [_endpoints]. An endpoint dropped without close() never
  /// cancels its transport subscription, never tears down its still-open
  /// responder streams, and never calls `dispose()` on its registered
  /// contracts -- so whatever a contract holds (database handles, files,
  /// subscriptions) stays held for the life of the process. One leak per
  /// client disconnect. [stop] closed endpoints correctly; only this path did
  /// not.
  void _releaseEndpoint(RpcResponderEndpoint endpoint, Socket socket) {
    _endpoints.remove(endpoint);
    unawaited(
      endpoint.close().catchError((Object error) {
        _logger?.warning('Ошибка при закрытии endpoint: $error');
      }),
    );
    _notify('onConnectionClosed', () => _onConnectionClosed?.call(socket));
  }

  /// Invokes an observability callback without letting it take the process out.
  ///
  /// These callbacks run on DETACHED paths -- [_handleConnection] off the
  /// server socket's listen, [_releaseEndpoint] off `socket.done`'s
  /// then/catchError -- so a throw has no handler above it and reaches the root
  /// zone, where an unhandled async error kills the isolate.
  ///
  /// Measured: a callback that throws from `onConnectionOpened` ended the
  /// process outright --
  ///   Unhandled exception: Bad state: user callback failed on open
  ///   #1 RpcHttp2Server._handleConnection (rpc_http2_server.dart:260)
  ///   #2 _RootZone.runUnaryGuarded
  /// -- because that call sits outside the try below. `onConnectionClosed` is
  /// conditionally fatal: a throw on the graceful `.then` path is absorbed by
  /// the `.catchError` that follows it, but a throw on the `.catchError` path
  /// has nothing after it and escapes the same way.
  ///
  /// Reaching this needs no misuse. A callback that reads `socket.remotePort`
  /// on close throws `OS Error 22` by itself, because the peer is already gone.
  ///
  /// Deliberately NOT applied to [_onEndpointCreated]: that one registers the
  /// contracts, so if it fails the connection is useless. The surrounding
  /// try/catch already reports it and destroys the socket, which is the right
  /// outcome -- swallowing it would start an endpoint that serves nothing.
  void _notify(String what, void Function() body) {
    try {
      body();
    } catch (error, stackTrace) {
      _logger?.error(
        'Ошибка в пользовательском callback $what',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

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

    final scheme = isSecure ? 'h2 (TLS)' : 'h2c (plaintext)';
    _logger?.info('Запуск HTTP/2 сервера ($scheme) на $_host:$_port');

    try {
      final Stream<Socket> connections;
      if (_securityContext != null) {
        // TLS with ALPN: only negotiate HTTP/2 ('h2'). Clients that do not
        // offer 'h2' will fail ALPN negotiation, which is the desired behavior
        // for an h2-only server.
        _secureServerSocket = await SecureServerSocket.bind(
          _host,
          _port,
          _securityContext,
          supportedProtocols: const ['h2'],
        );
        connections = _secureServerSocket!;
      } else {
        _serverSocket = await ServerSocket.bind(_host, _port);
        connections = _serverSocket!;
      }
      _isRunning = true;

      _logger?.info('HTTP/2 сервер запущен ($scheme) на $_host:$port');

      // Слушаем входящие соединения
      final subscription = connections.listen(
        _handleConnection,
        onError: (error, stackTrace) {
          _logger?.error(
            'Ошибка сервера',
            error: error,
            stackTrace: stackTrace,
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, stackTrace),
          );
        },
      );

      _subscriptions.add(subscription);
    } catch (e, stackTrace) {
      _logger?.error(
        'Не удалось запустить HTTP/2 сервер',
        error: e,
        stackTrace: stackTrace,
      );
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

    // Закрываем все endpoints.
    // Iterate over a snapshot: closing an endpoint can trigger socket.done,
    // whose handler removes the endpoint from _endpoints, mutating the list
    // mid-iteration ("Concurrent modification during iteration").
    final endpointsToClose = List.of(_endpoints);
    _endpoints.clear();
    for (final endpoint in endpointsToClose) {
      try {
        await endpoint.close();
      } catch (e) {
        _logger?.warning('Ошибка при закрытии endpoint: $e');
      }
    }

    // Закрываем серверный сокет
    await _serverSocket?.close();
    _serverSocket = null;
    await _secureServerSocket?.close();
    _secureServerSocket = null;

    _logger?.info('HTTP/2 сервер остановлен');
  }

  /// Обрабатывает новое HTTP/2 соединение
  void _handleConnection(Socket socket) {
    final clientAddress = '${socket.remoteAddress}:${socket.remotePort}';
    _logger?.debug('Новое HTTP/2 подключение от $clientAddress');

    _notify('onConnectionOpened', () => _onConnectionOpened?.call(socket));

    try {
      // Создаем HTTP/2 соединение
      final connection = http2.ServerTransportConnection.viaSocket(socket);

      // Создаем серверный транспорт (правильный способ!)
      IRpcTransport transport = RpcHttp2ResponderTransport(
        connection: connection,
        policy: _securityPolicy,
        logger: _logger,
      );

      if (_transportWrapper != null) {
        try {
          transport = _transportWrapper(transport, socket);
        } catch (error, stackTrace) {
          _logger?.error(
            'Ошибка при обёртке транспорта',
            error: error,
            stackTrace: stackTrace,
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(error, stackTrace),
          );
          socket.destroy();
          return;
        }
      }

      // Создаем RPC endpoint
      final endpoint = RpcResponderEndpoint(
        transport: transport,
        debugLabel: 'Http2Endpoint-$clientAddress',
        logger: _logController,
      );

      _endpoints.add(endpoint);

      // Уведомляем о создании endpoint'а
      _onEndpointCreated?.call(endpoint);

      // Запускаем endpoint
      endpoint.start();

      _logger?.debug('RPC endpoint создан для $clientAddress');

      // Обрабатываем закрытие соединения
      socket.done
          .then((_) {
            _logger?.debug('HTTP/2 соединение $clientAddress закрыто');
            _releaseEndpoint(endpoint, socket);
          })
          .catchError((error) {
            _logger?.warning(
              'Ошибка при закрытии соединения $clientAddress: $error',
            );
            _releaseEndpoint(endpoint, socket);
          });
    } catch (e, stackTrace) {
      _logger?.error(
        'Ошибка при создании HTTP/2 RPC соединения',
        error: e,
        stackTrace: stackTrace,
      );
      _notify(
        'onConnectionError',
        () => _onConnectionError?.call(e, stackTrace),
      );
      socket.destroy();
    }
  }
}
