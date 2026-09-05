// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import 'http2_header_block_guard.dart';
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
        // Advertise 'h2' for ALPN. This is what the API asks for, but do NOT
        // treat it as a filter: it is not one here.
        //
        // The previous comment claimed "clients that do not offer 'h2' will
        // fail ALPN negotiation, which is the desired behavior for an h2-only
        // server". Measured, that is false in both directions. openssl against
        // this server, and against a BARE SecureServerSocket given the same
        // `supportedProtocols: ['h2']` as a control:
        //
        //   client offers h2        -> CONNECTION ESTABLISHED (TLSv1.3),
        //                              "No ALPN negotiated",
        //                              server-side selectedProtocol = null
        //   client offers http/1.1  -> CONNECTION ESTABLISHED, same
        //   client offers no ALPN   -> CONNECTION ESTABLISHED, same
        //
        // The control matters: the bare socket behaves identically, so nothing
        // here causes it -- it is the platform's TLS/ALPN behaviour (measured
        // on macOS, Dart 3.10.1, OpenSSL 3.x; other platforms unverified).
        //
        // Two consequences worth knowing before relying on this:
        //  - No client is rejected for its protocol list. A browser, a health
        //    checker or a scanner completes the handshake and is then handed
        //    to the h2 parser, which is where it fails instead. ALPN is not an
        //    access control here.
        //  - RFC 7540 requires ALPN for h2 over TLS, so a STRICT gRPC client
        //    may refuse to proceed without a negotiated 'h2'. grpcurl (Go) is
        //    lenient and interoperates fine over TLS -- verified, including
        //    reflection, unary and server-streaming -- but that is the client
        //    being forgiving, not a negotiated protocol.
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

    // See the assignment below. Measured on this server with a callback that
    // throws on every connection, three connections:
    //
    //   endpoints held     : 3   (want 0)
    //   contracts disposed : 0   (want 3)
    //
    // one permanent leak per failed connection, holding the application's
    // contracts. Same defect and same ordering as the websocket server; a
    // throwing onEndpointCreated is ordinary, because that callback is where
    // the application registers its contracts.
    RpcResponderEndpoint? created;

    try {
      // Создаем HTTP/2 соединение.
      //
      // The incoming byte stream is passed through a header-block guard before
      // package:http2 sees it: that library concatenates a HEADERS frame and
      // its CONTINUATION frames with no bound (and O(N^2) recopy), so a peer
      // that opens a header block and never ends it floods the server's event
      // loop below every rpc_dart limit. See http2_header_block_guard.dart.
      // Outbound is the raw socket; only the read side is guarded.
      final guardedIncoming = guardHttp2HeaderBlock(
        socket,
        maxHeaderBlockBytes: _securityPolicy.maxMetadataBytes,
        onViolation: (observedBytes) {
          _logger?.warning(
            'HTTP/2 header-block cap exceeded from $clientAddress: '
            '$observedBytes bytes (max: ${_securityPolicy.maxMetadataBytes}); '
            'closing connection',
          );
          _notify(
            'onConnectionError',
            () => _onConnectionError?.call(
              StateError(
                'HTTP/2 header block exceeded ${_securityPolicy.maxMetadataBytes} '
                'bytes ($observedBytes observed): probable CONTINUATION flood',
              ),
              StackTrace.current,
            ),
          );
          socket.destroy();
        },
      );
      final connection = http2.ServerTransportConnection.viaStreams(
        guardedIncoming,
        socket,
      );

      // Создаем серверный транспорт (правильный способ!)
      IRpcTransport transport = RpcHttp2ResponderTransport(
        connection: connection,
        policy: _securityPolicy,
        logger: _logger,
      );

      if (_transportWrapper != null) {
        final inner = transport;
        try {
          transport = _preserveCapabilities(
            inner,
            _transportWrapper(inner, socket),
          );
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
      // Remembered so the catch below can release it if the user callback
      // throws: the endpoint is registered here, BEFORE that callback, and the
      // `socket.done` release wiring is only installed after it.
      created = endpoint;

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
      // Release what was already registered. _releaseEndpoint removes it,
      // closes it -- which is what disposes the contracts -- and fires
      // onConnectionClosed, balancing the onConnectionOpened above for a
      // connection now being torn down.
      final orphan = created;
      if (orphan != null) _releaseEndpoint(orphan, socket);
      socket.destroy();
    }
  }
}

/// Keeps the capability interfaces the wrapper dropped.
///
/// The endpoint layers find optional transport capabilities with `is` checks
/// and fall back to a default when the check fails -- silently. So the obvious
/// decorator (implement [IRpcTransport], forward every method) removes them:
/// the responder pipeline then reads `const RpcSecurityPolicy()` instead of the
/// policy this server was configured with. Measured with a plain counting
/// wrapper against `maxActiveStreams: 3`, a peer opening 60 concurrent streams
/// went from 3 admitted to 60 -- the ceiling was simply gone, and nothing said
/// so: the wrapper compiles and every call works.
///
/// A decorator that wants to CHANGE the policy declares
/// [IRpcSecurityPolicyAware] itself and is left alone; there is no other way to
/// express that intent, so a wrapper that declares nothing is an oversight
/// rather than a choice. Restoring is therefore what the author meant.
IRpcTransport _preserveCapabilities(
  IRpcTransport inner,
  IRpcTransport wrapped,
) {
  if (identical(inner, wrapped)) return wrapped;
  final needsPolicy =
      inner is IRpcSecurityPolicyAware && wrapped is! IRpcSecurityPolicyAware;
  final needsFlow =
      inner is IRpcFlowControlled && wrapped is! IRpcFlowControlled;
  if (!needsPolicy && !needsFlow) return wrapped;
  return _CapabilityPreservingTransport(inner: inner, wrapped: wrapped);
}

/// Delegates [IRpcTransport] to the user's wrapper and the capabilities to the
/// transport it wrapped. See [_preserveCapabilities].
class _CapabilityPreservingTransport
    implements IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled {
  _CapabilityPreservingTransport({required this.inner, required this.wrapped});

  /// The transport handed to the wrapper; the source of the capabilities.
  final IRpcTransport inner;

  /// What the wrapper returned; every call still goes through it.
  final IRpcTransport wrapped;

  // Explicit casts, not `is`-promotion: IRpcSecurityPolicyAware and
  // IRpcFlowControlled are neither subtypes nor supertypes of IRpcTransport, so
  // Dart forms no intersection type and an `is` test promotes nothing. Core
  // reads the same capabilities the same way.
  @override
  RpcSecurityPolicy get securityPolicy {
    final outer = wrapped;
    if (outer is IRpcSecurityPolicyAware) {
      return (outer as IRpcSecurityPolicyAware).securityPolicy;
    }
    final source = inner;
    if (source is IRpcSecurityPolicyAware) {
      return (source as IRpcSecurityPolicyAware).securityPolicy;
    }
    return const RpcSecurityPolicy();
  }

  /// Prefers the wrapper when it implements the capability, so a decorator that
  /// meters flow control keeps control of it.
  IRpcFlowControlled? get _flowControlled {
    final outer = wrapped;
    if (outer is IRpcFlowControlled) return outer as IRpcFlowControlled;
    final source = inner;
    if (source is IRpcFlowControlled) return source as IRpcFlowControlled;
    return null;
  }

  @override
  void deferFlowCredit(int streamId) =>
      _flowControlled?.deferFlowCredit(streamId);

  @override
  void returnFlowCredit(int streamId, int bytes) =>
      _flowControlled?.returnFlowCredit(streamId, bytes);

  @override
  bool get isClient => wrapped.isClient;
  @override
  bool get isClosed => wrapped.isClosed;
  @override
  bool get supportsZeroCopy => wrapped.supportsZeroCopy;
  @override
  Stream<RpcTransportMessage> get incomingMessages => wrapped.incomingMessages;
  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      wrapped.getMessagesForStream(streamId);
  @override
  int createStream() => wrapped.createStream();
  @override
  bool releaseStreamId(int streamId) => wrapped.releaseStreamId(streamId);
  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) => wrapped.sendMetadata(streamId, metadata, endStream: endStream);
  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) => wrapped.sendMessage(streamId, data, endStream: endStream);
  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) => wrapped.sendDirectObject(streamId, object, endStream: endStream);
  @override
  Future<void> finishSending(int streamId) => wrapped.finishSending(streamId);
  @override
  Future<RpcHealthStatus> health() => wrapped.health();
  @override
  Future<RpcHealthStatus> reconnect() => wrapped.reconnect();
  @override
  Future<void> close() => wrapped.close();
}
