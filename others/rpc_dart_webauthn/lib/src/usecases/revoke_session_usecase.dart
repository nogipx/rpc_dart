part of '_index.dart';

/// Параметры для отзыва сессии
@freezed
abstract class RevokeSessionParams
    with _$RevokeSessionParams
    implements IRpcSerializable {
  const factory RevokeSessionParams({
    required String sessionId,
    String? reason,
  }) = _RevokeSessionParams;

  static IRpcCodec<RevokeSessionParams> get codec =>
      RpcCodec(RevokeSessionParams.fromJson);

  factory RevokeSessionParams.fromJson(Map<String, dynamic> json) =>
      _$RevokeSessionParamsFromJson(json);
}

/// Параметры для отзыва всех сессий пользователя
@freezed
abstract class RevokeAllSessionsParams
    with _$RevokeAllSessionsParams
    implements IRpcSerializable {
  const factory RevokeAllSessionsParams({
    required String userId,
    String? reason,
  }) = _RevokeAllSessionsParams;

  static IRpcCodec<RevokeAllSessionsParams> get codec =>
      RpcCodec(RevokeAllSessionsParams.fromJson);

  factory RevokeAllSessionsParams.fromJson(Map<String, dynamic> json) =>
      _$RevokeAllSessionsParamsFromJson(json);
}

/// Результат отзыва сессий
@freezed
abstract class RevokeSessionResult
    with _$RevokeSessionResult
    implements IRpcSerializable {
  factory RevokeSessionResult._({
    required bool success,
    required int revokedCount,
    String? message,
    WebAuthnException? error,
  }) = _RevokeSessionResult;

  static IRpcCodec<RevokeSessionResult> get codec =>
      RpcCodec(RevokeSessionResult.fromJson);

  factory RevokeSessionResult.fromJson(Map<String, dynamic> json) =>
      _$RevokeSessionResultFromJson(json);

  factory RevokeSessionResult.success({
    required int revokedCount,
    String? message,
  }) {
    return RevokeSessionResult._(
      success: true,
      revokedCount: revokedCount,
      message: message,
    );
  }

  factory RevokeSessionResult.failure(
    String message, [
    WebAuthnException? error,
  ]) {
    return RevokeSessionResult._(
      success: false,
      revokedCount: 0,
      message: message,
      error: error,
    );
  }
}

/// Use Case для отзыва сессий
class RevokeSessionUseCase {
  final ISessionRepository _sessionRepository;

  RevokeSessionUseCase(this._sessionRepository);

  /// Отзывает конкретную сессию
  Future<RevokeSessionResult> revokeSession(RevokeSessionParams params) async {
    try {
      // 1. Проверяем, существует ли сессия
      final session = await _sessionRepository.getSession(params.sessionId);
      if (session == null) {
        return RevokeSessionResult.failure('Сессия не найдена');
      }

      // 2. Отзываем сессию
      await _sessionRepository.revokeSession(params.sessionId);

      return RevokeSessionResult.success(
        revokedCount: 1,
        message: 'Сессия успешно отозвана',
      );
    } on WebAuthnException catch (e) {
      return RevokeSessionResult.failure(e.message, e);
    } catch (e) {
      return RevokeSessionResult.failure(
        'Ошибка отзыва сессии: ${e.toString()}',
      );
    }
  }

  /// Отзывает все сессии пользователя
  Future<RevokeSessionResult> revokeAllSessions(
    RevokeAllSessionsParams params,
  ) async {
    try {
      // 1. Получаем все активные сессии пользователя
      final activeSessions = await _sessionRepository.getUserActiveSessions(
        params.userId,
      );

      if (activeSessions.isEmpty) {
        return RevokeSessionResult.success(
          revokedCount: 0,
          message: 'У пользователя нет активных сессий',
        );
      }

      // 2. Отзываем все сессии пользователя
      await _sessionRepository.revokeAllUserSessions(params.userId);

      return RevokeSessionResult.success(
        revokedCount: activeSessions.length,
        message: 'Все сессии пользователя успешно отозваны',
      );
    } on WebAuthnException catch (e) {
      return RevokeSessionResult.failure(e.message, e);
    } catch (e) {
      return RevokeSessionResult.failure(
        'Ошибка отзыва сессий: ${e.toString()}',
      );
    }
  }
}
