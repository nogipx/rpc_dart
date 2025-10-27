part of '_index.dart';

@freezed
abstract class WebAuthnUserInfo
    with _$WebAuthnUserInfo
    implements IRpcSerializable {
  const WebAuthnUserInfo._();

  const factory WebAuthnUserInfo({
    required List<WebAuthnCredentialPublic> credentials,
    required WebAuthnCredentialPublic? authenticatedCredential,
    required WebAuthnException? error,
  }) = _WebAuthnUserInfo;

  factory WebAuthnUserInfo.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnUserInfoFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnUserInfo> get codec =>
      RpcCodec(WebAuthnUserInfo.fromJson);

  factory WebAuthnUserInfo.success(
    List<WebAuthnCredentialPublic> credentials,
    WebAuthnCredentialPublic? authenticatedCredential,
  ) {
    return WebAuthnUserInfo(
      credentials: credentials,
      authenticatedCredential: authenticatedCredential,
      error: null,
    );
  }

  factory WebAuthnUserInfo.failure(WebAuthnException error) {
    return WebAuthnUserInfo(
      credentials: [],
      authenticatedCredential: null,
      error: error,
    );
  }
}
