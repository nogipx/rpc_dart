part of '_index.dart';

class RegistrationOptions implements IRpcSerializable {
  final List<int> challenge;
  final String rpId;
  final String rpName;
  final String userId;
  final List<int> userHandle;
  final String userName;
  final String userDisplayName;
  final List<Map<String, dynamic>> pubKeyCredParams;
  final Map<String, dynamic> authenticatorSelection;
  final int timeout;
  final String attestation;

  const RegistrationOptions({
    required this.challenge,
    required this.rpId,
    required this.rpName,
    required this.userId,
    required this.userHandle,
    required this.userName,
    required this.userDisplayName,
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

    final userJson = Map<String, dynamic>.from(json['publicKey']['user'] as Map<String, dynamic>);

    final userHandle = WebAuthnSafeBase64.decode(userJson['id'] as String);
    final userName = userJson['name']?.toString() ?? '';
    final userDisplayName = userJson['displayName']?.toString() ?? userName;

    return RegistrationOptions(
      challenge: WebAuthnSafeBase64.decode(json['publicKey']['challenge']),
      rpId: json['publicKey']['rp']['id'],
      rpName: json['publicKey']['rp']['name'],
      userId: userJson['id'] as String,
      userHandle: userHandle,
      userName: userName,
      userDisplayName: userDisplayName,
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
        'user': {
          'id': WebAuthnSafeBase64.encode(userHandle),
          'name': userName,
          'displayName': userDisplayName,
        },
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
    List<int>? userHandle,
    String? userName,
    String? userDisplayName,
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
      userHandle: userHandle ?? this.userHandle,
      userName: userName ?? this.userName,
      userDisplayName: userDisplayName ?? this.userDisplayName,
      pubKeyCredParams: pubKeyCredParams ?? this.pubKeyCredParams,
      authenticatorSelection: authenticatorSelection ?? this.authenticatorSelection,
      timeout: timeout ?? this.timeout,
      attestation: attestation ?? this.attestation,
    );
  }

  @override
  String toString() => toJson().toString();
}
