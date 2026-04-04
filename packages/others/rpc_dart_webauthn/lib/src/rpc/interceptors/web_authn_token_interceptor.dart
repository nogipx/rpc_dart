import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

import '../../../rpc_dart_webauthn.dart';

/// Представление сохранённого access-токена WebAuthn.
///
/// Содержит сам PASETO, время истечения и идентификатор пользователя.
class WebAuthnTokenState {
  WebAuthnTokenState({
    required this.accessToken,
    required this.expiresAt,
    required this.userId,
  });

  /// Создает [WebAuthnTokenState] из ответа [AuthResponse].
  factory WebAuthnTokenState.fromAuthResponse(
    AuthResponse response, {
    DateTime? issuedAt,
  }) {
    final issued = issuedAt ?? DateTime.now();
    return WebAuthnTokenState(
      accessToken: response.accessToken,
      userId: response.userId,
      expiresAt: issued.add(Duration(seconds: response.expiresIn)),
    );
  }

  /// Bearer-токен, который нужно отправлять в `Authorization`.
  final String accessToken;

  /// Момент времени, когда PASETO становится недействительным.
  final DateTime expiresAt;

  /// Идентификатор пользователя, которому принадлежит токен.
  final String userId;

  /// Просрочен ли токен.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Истекает ли токен в течение указанного окна.
  bool willExpireWithin(Duration window) {
    final threshold = expiresAt.subtract(window);
    return DateTime.now().isAfter(threshold);
  }
}

/// Возвращает текущее состояние access-токена.
typedef WebAuthnTokenProvider = FutureOr<WebAuthnTokenState?> Function();

/// Сохраняет новое состояние токена после refresh.
typedef WebAuthnTokenSaver =
    FutureOr<void> Function(WebAuthnTokenState state, AuthResponse response);

/// Колбэк, вызываемый при ошибке обновления токена.
typedef WebAuthnRefreshFailureCallback =
    FutureOr<void> Function(Object error, StackTrace? stackTrace);

/// Выполняет обновление access-токена через WebAuthn-домен.
typedef WebAuthnRefreshCallback =
    Future<AuthResponse?> Function(
      String expiredToken,
      RpcMiddlewareContext call,
    );

/// Определяет, нужно ли пытаться обновить токен при ошибке RPC.
typedef WebAuthnRefreshPredicate =
    bool Function(RpcMiddlewareContext call, Object error);

/// Формирует значение заголовка Authorization.
typedef WebAuthnHeaderValueBuilder = String Function(String token);

/// Клиентский interceptor, который добавляет PASETO-токен в RPC-контекст
/// и автоматически обновляет его при истечении срока или ответе сервера
/// об ошибке авторизации.
class WebAuthnTokenInterceptor extends IRpcInterceptor {
  WebAuthnTokenInterceptor({
    required WebAuthnTokenProvider tokenProvider,
    required WebAuthnRefreshCallback refreshCallback,
    WebAuthnTokenSaver? onTokenRefreshed,
    WebAuthnRefreshFailureCallback? onRefreshFailed,
    WebAuthnRefreshPredicate? shouldRefreshOnError,
    WebAuthnHeaderValueBuilder? headerValueBuilder,
    this.authorizationHeader = 'authorization',
    this.refreshThreshold = const Duration(seconds: 30),
    this.refreshServiceName = IWebAuthnContract.serviceNameConst,
    this.refreshMethodName = IWebAuthnContract.refreshTokenMethod,
  }) : _tokenProvider = tokenProvider,
       _refreshCallback = refreshCallback,
       _onTokenRefreshed = onTokenRefreshed,
       _onRefreshFailed = onRefreshFailed,
       _shouldRefreshOnError =
           shouldRefreshOnError ??
           WebAuthnTokenInterceptor._defaultShouldRefresh,
       _headerValueBuilder = headerValueBuilder ?? _defaultHeaderValueBuilder;

  final WebAuthnTokenProvider _tokenProvider;
  final WebAuthnRefreshCallback _refreshCallback;
  final WebAuthnTokenSaver? _onTokenRefreshed;
  final WebAuthnRefreshFailureCallback? _onRefreshFailed;
  final WebAuthnRefreshPredicate _shouldRefreshOnError;
  final WebAuthnHeaderValueBuilder _headerValueBuilder;

  /// Имя заголовка, в который будет записан bearer-токен.
  final String authorizationHeader;

  /// Через сколько до истечения срока нужно запустить refresh проактивно.
  final Duration refreshThreshold;

  /// Имя сервиса/метода, которые используются для refreshToken.
  final String refreshServiceName;
  final String refreshMethodName;

  Future<WebAuthnTokenState?>? _ongoingRefresh;

  static bool _defaultShouldRefresh(RpcMiddlewareContext call, Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('token') ||
        message.contains('unauth') ||
        message.contains('expired');
  }

  static String _defaultHeaderValueBuilder(String token) => 'Bearer $token';

  bool _isRefreshInvocation(RpcMiddlewareContext call) {
    return call.serviceName == refreshServiceName &&
        call.methodName == refreshMethodName;
  }

  Future<WebAuthnTokenState?> _maybeRefreshToken(
    WebAuthnTokenState state,
    RpcMiddlewareContext call,
  ) async {
    if (!state.isExpired && !state.willExpireWithin(refreshThreshold)) {
      return state;
    }

    final refreshed = await _refreshToken(state.accessToken, call);
    return refreshed ?? state;
  }

  Future<WebAuthnTokenState?> _refreshToken(
    String expiredToken,
    RpcMiddlewareContext call,
  ) {
    if (_ongoingRefresh != null) {
      return _ongoingRefresh!;
    }

    final completer = Completer<WebAuthnTokenState?>();
    _ongoingRefresh = completer.future;

    () async {
      try {
        final response = await _refreshCallback(expiredToken, call);
        if (response == null) {
          completer.complete(null);
          return;
        }

        final state = WebAuthnTokenState.fromAuthResponse(response);
        await _onTokenRefreshed?.call(state, response);
        completer.complete(state);
      } catch (error, stackTrace) {
        await _onRefreshFailed?.call(error, stackTrace);
        completer.completeError(error, stackTrace);
      } finally {
        _ongoingRefresh = null;
      }
    }();

    return _ongoingRefresh!;
  }

  RpcContext _contextWithToken(RpcContext original, String? token) {
    if (token == null || token.isEmpty) {
      return original;
    }

    return original.withAdditionalHeaders({
      authorizationHeader: _headerValueBuilder(token),
    });
  }

  bool _canRetry(
    Object error,
    WebAuthnTokenState? currentState,
    RpcMiddlewareContext call,
  ) {
    if (currentState == null) {
      return false;
    }

    if (_isRefreshInvocation(call)) {
      return false;
    }

    return _shouldRefreshOnError(call, error);
  }

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcMiddlewareContext call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) async {
    // Для refreshToken не модифицируем поведение, чтобы избежать рекурсии.
    if (_isRefreshInvocation(call)) {
      return next(call.context, request);
    }

    var tokenState = await Future<WebAuthnTokenState?>.value(_tokenProvider());

    if (tokenState != null) {
      tokenState = await _maybeRefreshToken(tokenState, call);
    }

    final contextWithToken = _contextWithToken(
      call.context,
      tokenState?.accessToken,
    );

    try {
      return await next(contextWithToken, request);
    } catch (error) {
      if (!_canRetry(error, tokenState, call)) {
        rethrow;
      }

      final refreshedState = await _refreshToken(tokenState!.accessToken, call);

      if (refreshedState == null) {
        rethrow;
      }

      final retryContext = _contextWithToken(
        call.context,
        refreshedState.accessToken,
      );

      return next(retryContext, request);
    }
  }
}
