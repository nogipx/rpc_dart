part of '_index.dart';

/// Ответ на запрос авторизации
@freezed
abstract class AuthResponse with _$AuthResponse implements IRpcSerializable {
  const factory AuthResponse({
    /// Токен доступа (PASETO)
    required String accessToken,

    /// Время истечения в секундах от текущего момента
    required int expiresIn,

    /// Идентификатор пользователя
    required String userId,

    /// Тип токена (всегда paseto)
    @Default('paseto') String tokenType,

    /// Дополнительная информация о пользователе (опционально)
    WebAuthnCredentialPublic? credential,
  }) = _AuthResponse;

  /// Создает ответ из JSON
  factory AuthResponse.fromJson(Map<String, dynamic> json) => _$AuthResponseFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<AuthResponse> get codec => RpcCodec(AuthResponse.fromJson);
}
