part of '_index.dart';

class AuthenticationOptions implements IRpcSerializable {
  final List<int> challenge;
  final String rpId;
  final List<Map<String, dynamic>> allowCredentials;
  final int timeout;
  final String userVerification;

  const AuthenticationOptions({
    required this.challenge,
    required this.rpId,
    required this.allowCredentials,
    required this.timeout,
    required this.userVerification,
  });

  factory AuthenticationOptions.fromJson(Map<String, dynamic> json) {
    final dynamic credsRaw = json['publicKey']['allowCredentials'];
    final List<Map<String, dynamic>> allowCredentials = credsRaw is List
        ? credsRaw.map((item) => item as Map<String, dynamic>).toList()
        : [];

    return AuthenticationOptions(
      challenge: WebAuthnSafeBase64.decode(json['publicKey']['challenge']),
      rpId: json['publicKey']['rpId'],
      allowCredentials: allowCredentials,
      timeout: int.parse(json['publicKey']['timeout'].toString()),
      userVerification: json['publicKey']['userVerification'],
    );
  }

  // Конвертация в формат, ожидаемый клиентом
  @override
  Map<String, dynamic> toJson() {
    return {
      'publicKey': {
        'challenge': WebAuthnSafeBase64.encode(challenge),
        'rpId': rpId,
        'allowCredentials': allowCredentials,
        'timeout': timeout,
        'userVerification': userVerification,
      },
    };
  }

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<AuthenticationOptions> get codec =>
      RpcCodec(AuthenticationOptions.fromJson);

  AuthenticationOptions copyWith({
    List<int>? challenge,
    String? rpId,
    List<Map<String, dynamic>>? allowCredentials,
    int? timeout,
    String? userVerification,
  }) {
    return AuthenticationOptions(
      challenge: challenge ?? this.challenge,
      rpId: rpId ?? this.rpId,
      allowCredentials: allowCredentials ?? this.allowCredentials,
      timeout: timeout ?? this.timeout,
      userVerification: userVerification ?? this.userVerification,
    );
  }

  @override
  String toString() => toJson().toString();
}
