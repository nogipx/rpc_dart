part of '_index.dart';

/// Модель, представляющая параметры утверждения WebAuthn от клиента
/// Используется в процессе аутентификации
@freezed
abstract class WebAuthnAssertion with _$WebAuthnAssertion implements IRpcSerializable {
  const WebAuthnAssertion._();

  const factory WebAuthnAssertion({
    required String id,
    required WebAuthnAssertionResponse response,
  }) = _WebAuthnAssertion;

  factory WebAuthnAssertion.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAssertionFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnAssertion> get codec => RpcCodec(WebAuthnAssertion.fromJson);

  Map<String, dynamic>? get decodedClientData {
    try {
      final decoded = utf8.decode(response.clientDataJSON);
      return json.decode(decoded) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }
}

/// Модель, представляющая ответ от аутентификатора
@freezed
abstract class WebAuthnAssertionResponse
    with _$WebAuthnAssertionResponse
    implements IRpcSerializable {
  const WebAuthnAssertionResponse._();

  const factory WebAuthnAssertionResponse({
    required List<int> authenticatorData,
    required List<int> clientDataJSON,
    required List<int> signature,
    List<int>? userHandle,
  }) = _WebAuthnAssertionResponse;

  factory WebAuthnAssertionResponse.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnAssertionResponseFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnAssertionResponse> get codec =>
      RpcCodec(WebAuthnAssertionResponse.fromJson);
}
