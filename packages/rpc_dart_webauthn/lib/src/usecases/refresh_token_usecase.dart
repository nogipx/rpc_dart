part of '_index.dart';

/// Параметры обновления токена
class RefreshTokenParams implements IRpcSerializable {
  const RefreshTokenParams({required this.token, this.requestedScopes});

  factory RefreshTokenParams.fromJson(Map<String, dynamic> json) {
    return RefreshTokenParams(
      token: json['token'] as String,
      requestedScopes: (json['requestedScopes'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );
  }

  /// Токен, который необходимо обновить
  final String token;

  /// Необязательный список запрашиваемых скопов (должен быть подмножеством исходных)
  final List<String>? requestedScopes;

  static IRpcCodec<RefreshTokenParams> get codec =>
      RpcCodec(RefreshTokenParams.fromJson);

  @override
  Map<String, dynamic> toJson() {
    return {
      'token': token,
      if (requestedScopes != null) 'requestedScopes': requestedScopes,
    };
  }
}

/// Результат обновления токена
class RefreshTokenResult implements IRpcSerializable {
  const RefreshTokenResult({
    required this.success,
    this.authResponse,
    this.error,
  });

  factory RefreshTokenResult.fromJson(Map<String, dynamic> json) {
    return RefreshTokenResult(
      success: json['success'] as bool,
      authResponse: json['authResponse'] == null
          ? null
          : AuthResponse.fromJson(
              Map<String, dynamic>.from(json['authResponse'] as Map),
            ),
      error: json['error'] == null
          ? null
          : WebAuthnException.fromJson(
              Map<String, dynamic>.from(json['error'] as Map),
            ),
    );
  }

  final bool success;
  final AuthResponse? authResponse;
  final WebAuthnException? error;

  static IRpcCodec<RefreshTokenResult> get codec =>
      RpcCodec(RefreshTokenResult.fromJson);

  RefreshTokenResult copyWith({
    bool? success,
    AuthResponse? authResponse,
    WebAuthnException? error,
  }) {
    return RefreshTokenResult(
      success: success ?? this.success,
      authResponse: authResponse ?? this.authResponse,
      error: error ?? this.error,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      'authResponse': authResponse?.toJson(),
      'error': error?.toJson(),
    };
  }

  factory RefreshTokenResult.success(AuthResponse authResponse) {
    return RefreshTokenResult(success: true, authResponse: authResponse);
  }

  factory RefreshTokenResult.failure(WebAuthnException error) {
    return RefreshTokenResult(success: false, error: error);
  }
}

/// UseCase для обновления PASETO токена без повторного прохождения WebAuthn
class RefreshTokenUseCase {
  final IWebAuthnRepository _webAuthnRepository;
  final ISessionRepository _sessionRepository;
  final ITokenBlacklistRepository _tokenBlacklistRepository;
  final PasetoUtils _pasetoUtils;

  RefreshTokenUseCase(
    this._webAuthnRepository,
    this._sessionRepository,
    this._tokenBlacklistRepository,
    this._pasetoUtils,
  );

  Future<RefreshTokenResult> execute(RefreshTokenParams params) async {
    try {
      final payload = await _pasetoUtils.validateToken(params.token);
      if (payload == null) {
        return RefreshTokenResult.failure(
          WebAuthnException.authentication('Недействительный токен'),
        );
      }

      final isBlacklisted = await _tokenBlacklistRepository.isBlacklisted(
        payload.jti,
      );
      if (isBlacklisted) {
        return RefreshTokenResult.failure(
          WebAuthnException.authentication('Токен отозван'),
        );
      }

      final sessionId = payload.extra?['sessionId'] as String?;
      if (sessionId == null) {
        return RefreshTokenResult.failure(
          WebAuthnException.authentication(
            'Токен не содержит идентификатор сессии',
          ),
        );
      }

      final session = await _sessionRepository.getSession(sessionId);
      if (session == null || !session.isActive) {
        return RefreshTokenResult.failure(
          WebAuthnException.authentication('Сессия неактивна или истекла'),
        );
      }

      final credentialMap = Map<String, dynamic>.from(payload.extra ?? {});
      credentialMap.remove('sessionId');

      final credential = WebAuthnCredentialPublic.fromJson(credentialMap);
      final storedCredential = await _webAuthnRepository.getCredentialById(
        credential.credentialId,
      );

      if (storedCredential == null ||
          storedCredential.userId != credential.userId) {
        return RefreshTokenResult.failure(
          WebAuthnException.credential(
            'Учетные данные пользователя недействительны',
          ),
        );
      }

      final requestedScopes = params.requestedScopes;
      final originalScopes = payload.scopes.toSet();
      final scopes = requestedScopes == null
          ? payload.scopes
          : requestedScopes
                .where((scope) => originalScopes.contains(scope))
                .toList();

      if (requestedScopes != null && scopes.length != requestedScopes.length) {
        return RefreshTokenResult.failure(
          WebAuthnException.authorization(
            'Запрошенные скопы недоступны для текущего токена',
          ),
        );
      }

      final newExpiry = DateTime.now().add(
        Duration(seconds: _pasetoUtils.tokenLifetime),
      );

      await _sessionRepository.extendSession(
        sessionId,
        newExpiresAt: newExpiry,
        metadataUpdates: {'refreshedAt': DateTime.now().toIso8601String()},
      );

      await _tokenBlacklistRepository.addToBlacklist(
        payload.jti,
        userId: credential.userId,
        expiresAt: newExpiry,
        reason: 'token_rotated',
      );

      final updatedToken = await _pasetoUtils.createToken(
        userId: credential.userId,
        scopes: scopes,
        extra: {...storedCredential.public.toJson(), 'sessionId': sessionId},
      );

      final authResponse = AuthResponse(
        accessToken: updatedToken,
        expiresIn: _pasetoUtils.tokenLifetime,
        userId: credential.userId,
        credential: storedCredential.public,
      );

      return RefreshTokenResult.success(authResponse);
    } on WebAuthnException catch (e) {
      return RefreshTokenResult.failure(e);
    } catch (e, stackTrace) {
      return RefreshTokenResult.failure(
        WebAuthnException.authentication(e.toString(), stackTrace),
      );
    }
  }
}
