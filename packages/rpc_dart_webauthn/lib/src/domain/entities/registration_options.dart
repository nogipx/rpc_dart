part of '_index.dart';

class RegistrationOptions implements IRpcSerializable {
  final List<int> challenge;
  final String rpId;
  final String rpName;
  final String userId;
  final List<Map<String, dynamic>> pubKeyCredParams;
  final Map<String, dynamic> authenticatorSelection;
  final int timeout;
  final String attestation;

  const RegistrationOptions({
    required this.challenge,
    required this.rpId,
    required this.rpName,
    required this.userId,
    required this.pubKeyCredParams,
    required this.authenticatorSelection,
    required this.timeout,
    required this.attestation,
  });

  factory RegistrationOptions.fromJson(Map<String, dynamic> json) {
    final dynamic pubKeyCredsRaw = json['publicKey']['pubKeyCredParams'];
    final List<Map<String, dynamic>> pubKeyCredParams = pubKeyCredsRaw is List
        ? pubKeyCredsRaw.map((item) => item as Map<String, dynamic>).toList()
        : [];

    return RegistrationOptions(
      challenge: WebAuthnSafeBase64.decode(json['publicKey']['challenge']),
      rpId: json['publicKey']['rp']['id'],
      rpName: json['publicKey']['rp']['name'],
      userId: json['publicKey']['user']['id'],
      pubKeyCredParams: pubKeyCredParams,
      authenticatorSelection: json['publicKey']['authenticatorSelection'] as Map<String, dynamic>,
      timeout: int.parse(json['publicKey']['timeout'].toString()),
      attestation: json['publicKey']['attestation'],
    );
  }

  // Конвертация в формат, ожидаемый клиентом
  @override
  Map<String, dynamic> toJson() {
    return {
      'publicKey': {
        'challenge': WebAuthnSafeBase64.encode(challenge),
        'rp': {'name': rpName, 'id': rpId},
        'user': {'id': userId},
        'pubKeyCredParams': pubKeyCredParams,
        'authenticatorSelection': authenticatorSelection,
        'timeout': timeout,
        'attestation': attestation,
      },
    };
  }

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<RegistrationOptions> get codec => RpcCodec(RegistrationOptions.fromJson);

  RegistrationOptions copyWith({
    List<int>? challenge,
    String? rpId,
    String? rpName,
    String? userId,
    List<Map<String, dynamic>>? pubKeyCredParams,
    Map<String, dynamic>? authenticatorSelection,
    int? timeout,
    String? attestation,
  }) {
    return RegistrationOptions(
      challenge: challenge ?? this.challenge,
      rpId: rpId ?? this.rpId,
      rpName: rpName ?? this.rpName,
      userId: userId ?? this.userId,
      pubKeyCredParams: pubKeyCredParams ?? this.pubKeyCredParams,
      authenticatorSelection: authenticatorSelection ?? this.authenticatorSelection,
      timeout: timeout ?? this.timeout,
      attestation: attestation ?? this.attestation,
    );
  }

  @override
  String toString() => toJson().toString();
}
