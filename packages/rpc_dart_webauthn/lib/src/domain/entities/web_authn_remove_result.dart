part of '_index.dart';

@freezed
abstract class WebAuthnRemoveResult with _$WebAuthnRemoveResult implements IRpcSerializable {
  const WebAuthnRemoveResult._();

  const factory WebAuthnRemoveResult({
    required bool success,
    required WebAuthnException? error,
  }) = _WebAuthnRemoveResult;

  factory WebAuthnRemoveResult.fromJson(Map<String, dynamic> json) =>
      _$WebAuthnRemoveResultFromJson(json);

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnRemoveResult> get codec => RpcCodec(WebAuthnRemoveResult.fromJson);

  factory WebAuthnRemoveResult.success() {
    return WebAuthnRemoveResult(success: true, error: null);
  }

  factory WebAuthnRemoveResult.failure(WebAuthnException error) {
    return WebAuthnRemoveResult(success: false, error: error);
  }
}
