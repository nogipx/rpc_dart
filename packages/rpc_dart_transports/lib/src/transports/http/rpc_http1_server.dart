// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:universal_io/io.dart';

import '../../server/rpc_server_interface.dart';
import 'rpc_http1_responder_transport.dart';

/// Высокоуровневый HTTP/1.1 RPC сервер.
final class RpcHttp1Server implements IRpcServer {
  final String _host;
  int _port;
  final RpcLogger? _logger;
  final void Function(RpcResponderEndpoint endpoint)? _onEndpointCreated;
  final void Function(Object error, StackTrace? stackTrace)? _onRequestError;
  final IRpcTransport Function(IRpcTransport inner, HttpRequest request)?
      _transportWrapper;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  final List<RpcResponderEndpoint> _endpoints = [];
  bool _isRunning = false;

  RpcHttp1Server({
    String host = 'localhost',
    required int port,
    RpcLogger? logger,
    void Function(RpcResponderEndpoint endpoint)? onEndpointCreated,
    void Function(Object error, StackTrace? stackTrace)? onRequestError,
    IRpcTransport Function(IRpcTransport inner, HttpRequest request)?
        transportWrapper,
  })  : _host = host,
        _port = port,
        _logger = logger?.child('Http1Server'),
        _onEndpointCreated = onEndpointCreated,
        _onRequestError = onRequestError,
        _transportWrapper = transportWrapper;

  factory RpcHttp1Server.createWithContracts({
    required int port,
    required List<RpcResponderContract> contracts,
    String host = 'localhost',
    RpcLogger? logger,
  }) {
    return RpcHttp1Server(
      host: host,
      port: port,
      logger: logger,
      onEndpointCreated: (endpoint) {
        for (final contract in contracts) {
          endpoint.registerServiceContract(contract);
        }
      },
    );
  }

  @override
  String get host => _host;

  @override
  int get port => _port;

  @override
  bool get isRunning => _isRunning;

  @override
  List<RpcResponderEndpoint> get endpoints => List.unmodifiable(_endpoints);

  @override
  Future<void> start() async {
    if (_isRunning) {
      _logger?.warning('HTTP/1.1 сервер уже запущен');
      return;
    }

    _logger?.info('Запуск HTTP/1.1 сервера на $_host:$_port');

    _server = await HttpServer.bind(_host, _port);
    _port = _server!.port;
    _subscription = _server!.listen(
      _handleRequest,
      onError: (error, stackTrace) {
        _logger?.error('Ошибка HTTP сервера',
            error: error, stackTrace: stackTrace);
        _onRequestError?.call(error, stackTrace);
      },
    );

    _isRunning = true;
    _logger?.info('HTTP/1.1 сервер запущен на $_host:$_port');
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _logger?.info('Остановка HTTP/1.1 сервера');
    _isRunning = false;

    await _subscription?.cancel();
    await _server?.close(force: true);
    _subscription = null;
    _server = null;

    final endpoints = List<RpcResponderEndpoint>.from(_endpoints);
    _endpoints.clear();
    for (final endpoint in endpoints) {
      await endpoint.close();
    }

    _logger?.info('HTTP/1.1 сервер остановлен');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    late final RpcHttp1ResponderTransport transport;
    late final IRpcTransport effectiveTransport;

    try {
      transport = RpcHttp1ResponderTransport(
        request: request,
        logger: _logger,
      );
      final guard = _UnaryOnlyTransportGuard(baseTransport: transport);
      effectiveTransport = _transportWrapper?.call(guard, request) ?? guard;

      final endpoint = RpcResponderEndpoint(transport: effectiveTransport);
      _endpoints.add(endpoint);
      endpoint.start();
      _onEndpointCreated?.call(endpoint);
      guard.bindEndpoint(endpoint);
      guard.start();
      unawaited(request.response.done.then((_) => _cleanupEndpoint(endpoint)));
    } catch (error, stackTrace) {
      _logger?.error(
        'Ошибка при обработке HTTP запроса',
        error: error,
        stackTrace: stackTrace,
      );
      _onRequestError?.call(error, stackTrace);
      await request.response.close();
    }
  }

  Future<void> _cleanupEndpoint(RpcResponderEndpoint endpoint) async {
    if (!_endpoints.remove(endpoint)) return;
    try {
      await endpoint.close();
    } catch (error, stackTrace) {
      _logger?.error(
        'Ошибка при закрытии endpoint',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}

/// Транспорт-обертка, запрещающая стриминг и мультиплексирование.
final class _UnaryOnlyTransportGuard implements IRpcTransport {
  final RpcHttp1ResponderTransport baseTransport;
  final StreamController<RpcTransportMessage> _incomingController =
      StreamController<RpcTransportMessage>.broadcast();
  StreamSubscription<RpcTransportMessage>? _subscription;
  RpcResponderEndpoint? _endpoint;
  final Set<int> _blockedStreams = {};

  _UnaryOnlyTransportGuard({required this.baseTransport}) {
    _subscription = baseTransport.incomingMessages.listen(
      _handleIncomingMessage,
      onError: (error, stackTrace) {
        if (!_incomingController.isClosed) {
          _incomingController.addError(error, stackTrace);
        }
      },
      onDone: () {
        _incomingController.close();
      },
    );
  }

  void bindEndpoint(RpcResponderEndpoint endpoint) {
    _endpoint = endpoint;
  }

  void start() {
    baseTransport.start();
  }

  void _handleIncomingMessage(RpcTransportMessage message) {
    if (_shouldBlockMessage(message)) {
      final alreadyBlocked = !_blockedStreams.add(message.streamId);
      if (!alreadyBlocked) {
        _rejectStreamingCall(message.streamId, message.methodPath);
      }
      return;
    }

    if (!_incomingController.isClosed) {
      _incomingController.add(message);
    }
  }

  bool _shouldBlockMessage(RpcTransportMessage message) {
    final methodPath = message.methodPath;
    final binding = methodPath == null ? null : _findBindingForPath(methodPath);

    if (binding == null) {
      return false;
    }

    return binding.type != RpcMethodType.unaryRequest;
  }

  RpcResponderMethodBinding? _findBindingForPath(String methodPath) {
    final normalized = _methodKeyFromPath(methodPath);
    if (normalized == null) return null;
    final endpoint = _endpoint;
    if (endpoint == null) return null;
    return endpoint.registeredMethodBindings[normalized];
  }

  String? _methodKeyFromPath(String path) {
    if (!path.startsWith('/')) return null;
    final parts = path.substring(1).split('/');
    if (parts.length < 2) return null;
    return '${parts[0]}.${parts[1]}';
  }

  Future<void> _rejectStreamingCall(int streamId, String? methodPath) async {
    final metadata = RpcMetadata([
      RpcHeader(
        RpcConstants.grpcStatusHeader,
        RpcStatus.unimplemented.toString(),
      ),
      RpcHeader(
        RpcConstants.grpcMessageHeader,
        'HTTP/1.1 transport allows unary RPCs only',
      ),
      if (methodPath != null) RpcHeader('x-rpc-method', methodPath),
    ]);

    await baseTransport.sendMetadata(
      streamId,
      metadata,
      endStream: true,
    );
  }

  @override
  bool get isClient => baseTransport.isClient;

  @override
  bool get isClosed => baseTransport.isClosed;

  @override
  bool get supportsZeroCopy => baseTransport.supportsZeroCopy;

  @override
  int createStream() => baseTransport.createStream();

  @override
  bool releaseStreamId(int streamId) => baseTransport.releaseStreamId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) =>
      baseTransport.sendMetadata(
        streamId,
        metadata,
        endStream: endStream,
      );

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) =>
      baseTransport.sendMessage(
        streamId,
        data,
        endStream: endStream,
      );

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) =>
      baseTransport.sendDirectObject(
        streamId,
        object,
        endStream: endStream,
      );

  @override
  Stream<RpcTransportMessage> get incomingMessages =>
      _incomingController.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((message) => message.streamId == streamId);

  @override
  Future<void> finishSending(int streamId) =>
      baseTransport.finishSending(streamId);

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await baseTransport.close();
    await _incomingController.close();
  }

  @override
  Future<RpcHealthStatus> health() => baseTransport.health();

  @override
  Future<RpcHealthStatus> reconnect() => baseTransport.reconnect();
}
