part of '_index.dart';

/// Модель, представляющая учетные данные WebAuthn от клиента
/// Используется в процессе регистрации
@freezed
abstract class WebAuthnRegistrationCredential
    with _$WebAuthnRegistrationCredential
    implements IRpcSerializable {
  const WebAuthnRegistrationCredential._();

  const factory WebAuthnRegistrationCredential({
    required String id,
    required WebAuthnRegistrationResponse response,
    String? type,
    Map<String, dynamic>? transports,
  }) = _WebAuthnRegistrationCredential;

  factory WebAuthnRegistrationCredential.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRegistrationCredentialFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnRegistrationCredential> get codec =>
      RpcCodec(WebAuthnRegistrationCredential.fromJson);

  /// Декодирует clientDataJSON в читаемый объект
  Map<String, dynamic>? get decodedClientData {
    try {
      final decoded = utf8.decode(response.clientDataJSON);
      return json.decode(decoded) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}

/// Модель, представляющая ответ от аутентификатора при регистрации
@freezed
abstract class WebAuthnRegistrationResponse
    with _$WebAuthnRegistrationResponse
    implements IRpcSerializable {
  const WebAuthnRegistrationResponse._();

  const factory WebAuthnRegistrationResponse({
    @Uint8ListConverter() required Uint8List attestationObject,
    @Uint8ListConverter() required Uint8List clientDataJSON,
    // Опциональные поля для дополнительных данных
    Map<String, dynamic>? extensions,
  }) = _WebAuthnRegistrationResponse;

  factory WebAuthnRegistrationResponse.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRegistrationResponseFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnRegistrationResponse> get codec =>
      RpcCodec(WebAuthnRegistrationResponse.fromJson);
}
