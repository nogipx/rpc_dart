part of '_index.dart';

/// Модель контента PASETO токена
@freezed
abstract class PasetoTokenPayload with _$PasetoTokenPayload implements IRpcSerializable {
  const factory PasetoTokenPayload({
    /// Идентификатор пользователя
    required String sub,

    /// Время истечения срока действия токена (unix timestamp)
    required int exp,

    /// Время создания токена (unix timestamp)
    required int iat,

    /// Уникальный идентификатор токена
    required String jti,

    /// Список скопов пользователя
    required List<String> scopes,

    /// Дополнительные данные
    Map<String, dynamic>? extra,
  }) = _PasetoTokenPayload;

  /// Создает токен из JSON
  factory PasetoTokenPayload.fromJson(Map<String, dynamic> json) =>
      _$PasetoTokenPayloadFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<PasetoTokenPayload> get codec => RpcCodec(PasetoTokenPayload.fromJson);
}
