import 'package:rpc_dart/rpc_dart.dart';
import '../../rpc_dart_webauthn.dart';

/// WebAuthn Responder - обработчик RPC запросов
///
/// В CORD архитектуре это серверная часть домена, которая обрабатывает
/// входящие RPC вызовы и делегирует выполнение Use Cases.
/// Инкапсулирует бизнес-логику и обеспечивает изоляцию домена.
final class WebAuthnResponder extends RpcResponderContract
    implements IWebAuthnContract {
  final StartRegistrationUseCase _startRegistrationUseCase;
  final FinishRegistrationUseCase _finishRegistrationUseCase;
  final StartAuthenticationUseCase _startAuthenticationUseCase;
  final FinishAuthenticationUseCase _finishAuthenticationUseCase;
  final ValidateTokenUseCase _validateTokenUseCase;
  final RefreshTokenUseCase _refreshTokenUseCase;
  final RevokeSessionUseCase _revokeSessionUseCase;
  final IWebAuthnRepository _webAuthnRepository;
  final IWebAuthnAuthorizationService _authorizationService;

  WebAuthnResponder({
    required StartRegistrationUseCase startRegistrationUseCase,
    required FinishRegistrationUseCase finishRegistrationUseCase,
    required StartAuthenticationUseCase startAuthenticationUseCase,
    required FinishAuthenticationUseCase finishAuthenticationUseCase,
    required ValidateTokenUseCase validateTokenUseCase,
    required RefreshTokenUseCase refreshTokenUseCase,
    required RevokeSessionUseCase revokeSessionUseCase,
    required IWebAuthnRepository webAuthnRepository,
    required WebAuthnSettings settings,
    required IWebAuthnAuthorizationService authorizationService,
  }) : _startRegistrationUseCase = startRegistrationUseCase,
       _finishRegistrationUseCase = finishRegistrationUseCase,
       _startAuthenticationUseCase = startAuthenticationUseCase,
       _finishAuthenticationUseCase = finishAuthenticationUseCase,
       _validateTokenUseCase = validateTokenUseCase,
       _refreshTokenUseCase = refreshTokenUseCase,
       _revokeSessionUseCase = revokeSessionUseCase,
       _webAuthnRepository = webAuthnRepository,
       _authorizationService = authorizationService,
       super(IWebAuthnContract.serviceNameConst);

  @override
  void setup() {
    // ================ Основные методы WebAuthn ================

    addUnaryMethod<StartRegistrationParams, StartRegistrationResult>(
      methodName: IWebAuthnContract.startRegistrationMethod,
      handler: startRegistration,
      requestCodec: StartRegistrationParams.codec,
      responseCodec: StartRegistrationResult.codec,
    );

    addUnaryMethod<FinishRegistrationParams, FinishRegistrationResult>(
      methodName: IWebAuthnContract.finishRegistrationMethod,
      handler: finishRegistration,
      requestCodec: FinishRegistrationParams.codec,
      responseCodec: FinishRegistrationResult.codec,
    );

    addUnaryMethod<StartAuthenticationParams, StartAuthenticationResult>(
      methodName: IWebAuthnContract.startAuthenticationMethod,
      handler: startAuthentication,
      requestCodec: StartAuthenticationParams.codec,
      responseCodec: StartAuthenticationResult.codec,
    );

    addUnaryMethod<FinishAuthenticationParams, FinishAuthenticationResult>(
      methodName: IWebAuthnContract.finishAuthenticationMethod,
      handler: finishAuthentication,
      requestCodec: FinishAuthenticationParams.codec,
      responseCodec: FinishAuthenticationResult.codec,
    );

    // ================ Управление учетными данными ================

    addUnaryMethod<GetUserInfoParams, GetUserInfoResult>(
      methodName: IWebAuthnContract.getUserInfoMethod,
      handler: getUserInfo,
      requestCodec: GetUserInfoParams.codec,
      responseCodec: GetUserInfoResult.codec,
    );

    addUnaryMethod<RemoveCredentialParams, RemoveCredentialResult>(
      methodName: IWebAuthnContract.removeCredentialMethod,
      handler: removeCredential,
      requestCodec: RemoveCredentialParams.codec,
      responseCodec: RemoveCredentialResult.codec,
    );

    addUnaryMethod<GetCredentialsParams, GetCredentialsResult>(
      methodName: IWebAuthnContract.getCredentialsMethod,
      handler: getCredentials,
      requestCodec: GetCredentialsParams.codec,
      responseCodec: GetCredentialsResult.codec,
    );

    // ================ Управление токенами и сессиями ================

    addUnaryMethod<ValidateTokenParams, ValidateTokenResult>(
      methodName: IWebAuthnContract.validateTokenMethod,
      handler: validateToken,
      requestCodec: ValidateTokenParams.codec,
      responseCodec: ValidateTokenResult.codec,
    );

    addUnaryMethod<RefreshTokenParams, RefreshTokenResult>(
      methodName: IWebAuthnContract.refreshTokenMethod,
      handler: refreshToken,
      requestCodec: RefreshTokenParams.codec,
      responseCodec: RefreshTokenResult.codec,
    );

    addUnaryMethod<RevokeSessionParams, RevokeSessionResult>(
      methodName: IWebAuthnContract.revokeSessionMethod,
      handler: revokeSession,
      requestCodec: RevokeSessionParams.codec,
      responseCodec: RevokeSessionResult.codec,
    );

    addUnaryMethod<RevokeAllSessionsParams, RevokeSessionResult>(
      methodName: IWebAuthnContract.revokeAllSessionsMethod,
      handler: revokeAllSessions,
      requestCodec: RevokeAllSessionsParams.codec,
      responseCodec: RevokeSessionResult.codec,
    );
  }

  // ================ Helper методы ================

  /// Проверяет авторизацию для выполнения операции
  Future<WebAuthnAuthorizationContext> _checkAuthorization({
    required WebAuthnOperation operation,
    required RpcContext? context,
    String? targetUserId,
    String? targetSessionId,
    Map<String, dynamic>? additionalParams,
  }) async {
    // Извлекаем токен из заголовка Authorization
    final authHeader = context?.getHeader('authorization');
    if (authHeader == null || authHeader.isEmpty) {
      throw InvalidTokenException.missing();
    }

    // Извлекаем токен из Bearer заголовка
    String token;
    if (authHeader.startsWith('Bearer ')) {
      token = authHeader.substring(7); // Убираем "Bearer "
    } else {
      token = authHeader; // Используем как есть, если не Bearer
    }

    // Извлекаем контекст авторизации из токена
    final authContext = await _authorizationService.extractAuthorizationContext(
      token,
    );
    if (authContext == null) {
      throw InvalidTokenException.invalid();
    }

    // Проверяем права доступа
    final authResult = await _authorizationService.checkPermission(
      operation: operation,
      authContext: authContext,
      targetUserId: targetUserId,
      targetSessionId: targetSessionId,
      additionalParams: additionalParams,
    );

    if (!authResult.isAuthorized) {
      throw InvalidTokenException.insufficientPermissions(
        authResult.errorMessage,
      );
    }

    return authContext;
  }

  // ================ Handler методы ================

  @override
  Future<StartRegistrationResult> startRegistration(
    StartRegistrationParams request, {
    RpcContext? context,
  }) async {
    // Просто передаем параметры напрямую в юзкейс
    final result = await _startRegistrationUseCase.execute(request);

    return result;
  }

  @override
  Future<FinishRegistrationResult> finishRegistration(
    FinishRegistrationParams request, {
    RpcContext? context,
  }) async {
    // Просто передаем параметры напрямую в юзкейс
    final result = await _finishRegistrationUseCase.execute(request);
    return result;
  }

  @override
  Future<StartAuthenticationResult> startAuthentication(
    StartAuthenticationParams request, {
    RpcContext? context,
  }) async {
    // Просто передаем параметры напрямую в юзкейс
    final result = await _startAuthenticationUseCase.execute(request);
    return result;
  }

  @override
  Future<FinishAuthenticationResult> finishAuthentication(
    FinishAuthenticationParams request, {
    RpcContext? context,
  }) async {
    // Просто передаем параметры напрямую в юзкейс
    final result = await _finishAuthenticationUseCase.execute(request);
    return result;
  }

  @override
  Future<GetUserInfoResult> getUserInfo(
    GetUserInfoParams request, {
    RpcContext? context,
  }) async {
    try {
      // Проверяем авторизацию
      await _checkAuthorization(
        operation: WebAuthnOperation.getUserInfo,
        context: context,
        targetUserId: request.userId,
      );

      final credentials = await _webAuthnRepository.getCredentialsByUserId(
        request.userId,
      );

      if (credentials.isEmpty) {
        return GetUserInfoResult(
          success: false,
          errorMessage: 'Пользователь не найден или у него нет учетных данных',
        );
      }

      final userInfo = WebAuthnUserInfo.success(
        credentials.map((c) => c.public).toList(),
        null, // authenticatedCredential будет null для простоты
      );

      return GetUserInfoResult(success: true, userInfo: userInfo);
    } catch (e) {
      return GetUserInfoResult(
        success: false,
        errorMessage:
            'Ошибка получения информации о пользователе: ${e.toString()}',
      );
    }
  }

  @override
  Future<RemoveCredentialResult> removeCredential(
    RemoveCredentialParams request, {
    RpcContext? context,
  }) async {
    try {
      // Проверяем авторизацию
      await _checkAuthorization(
        operation: WebAuthnOperation.removeCredential,
        context: context,
        targetUserId: request.userId,
      );

      final credential = await _webAuthnRepository.getCredentialById(
        request.credentialId,
      );

      if (credential == null) {
        return RemoveCredentialResult(
          success: false,
          errorMessage: 'Учетные данные не найдены',
        );
      }

      if (credential.userId != request.userId) {
        return RemoveCredentialResult(
          success: false,
          errorMessage: 'Учетные данные принадлежат другому пользователю',
        );
      }

      await _webAuthnRepository.removeCredential(request.credentialId);

      return RemoveCredentialResult(
        success: true,
        message: 'Учетные данные успешно удалены',
      );
    } catch (e) {
      return RemoveCredentialResult(
        success: false,
        errorMessage: 'Ошибка удаления учетных данных: ${e.toString()}',
      );
    }
  }

  @override
  Future<GetCredentialsResult> getCredentials(
    GetCredentialsParams request, {
    RpcContext? context,
  }) async {
    try {
      // Проверяем авторизацию
      await _checkAuthorization(
        operation: WebAuthnOperation.getCredentials,
        context: context,
        targetUserId: request.userId,
      );

      final credentials = await _webAuthnRepository.getCredentialsByUserId(
        request.userId,
      );

      return GetCredentialsResult(
        success: true,
        credentials: credentials.map((c) => c.public).toList(),
      );
    } catch (e) {
      return GetCredentialsResult(
        success: false,
        errorMessage: 'Ошибка получения учетных данных: ${e.toString()}',
      );
    }
  }

  @override
  Future<ValidateTokenResult> validateToken(
    ValidateTokenParams request, {
    RpcContext? context,
  }) async {
    try {
      final result = await _validateTokenUseCase.execute(request);
      return result;
    } catch (e) {
      return ValidateTokenResult.failure(
        'Ошибка валидации токена: ${e.toString()}',
      );
    }
  }

  @override
  Future<RefreshTokenResult> refreshToken(
    RefreshTokenParams request, {
    RpcContext? context,
  }) async {
    try {
      final result = await _refreshTokenUseCase.execute(request);
      return result;
    } catch (e) {
      return RefreshTokenResult.failure(
        WebAuthnException.authentication(
          'Ошибка обновления токена: ${e.toString()}',
        ),
      );
    }
  }

  @override
  Future<RevokeSessionResult> revokeSession(
    RevokeSessionParams request, {
    RpcContext? context,
  }) async {
    try {
      // Проверяем авторизацию
      await _checkAuthorization(
        operation: WebAuthnOperation.revokeSession,
        context: context,
        targetSessionId: request.sessionId,
      );

      final result = await _revokeSessionUseCase.revokeSession(request);
      return result;
    } catch (e) {
      return RevokeSessionResult.failure(
        'Ошибка отзыва сессии: ${e.toString()}',
      );
    }
  }

  @override
  Future<RevokeSessionResult> revokeAllSessions(
    RevokeAllSessionsParams request, {
    RpcContext? context,
  }) async {
    try {
      // Проверяем авторизацию
      await _checkAuthorization(
        operation: WebAuthnOperation.revokeAllSessions,
        context: context,
        targetUserId: request.userId,
      );

      final result = await _revokeSessionUseCase.revokeAllSessions(request);
      return result;
    } catch (e) {
      return RevokeSessionResult.failure(
        'Ошибка отзыва всех сессий: ${e.toString()}',
      );
    }
  }
}
