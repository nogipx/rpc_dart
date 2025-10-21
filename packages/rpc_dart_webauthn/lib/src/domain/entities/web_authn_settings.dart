import '../../../rpc_dart_webauthn.dart';

/// Класс для хранения настроек WebAuthn
class WebAuthnSettings {
  /// Идентификатор RP (Relying Party)
  final String rpId;

  /// Имя RP (Relying Party)
  final String rpName;

  /// Конфигурация origin для разных платформ
  final WebAuthnOriginConfig originConfig;

  /// Конфигурация продукта
  ProductConfig get productConfig => originConfig.productConfig;

  /// Требуется ли верификация пользователя
  final bool requireUserVerification;

  /// Время жизни challenge в секундах
  final int challengeTimeout;

  /// Время жизни токена в секундах
  final int tokenLifetime;

  /// Скопы для пользователя
  final List<String> scopes;

  /// Конструктор
  const WebAuthnSettings({
    required this.rpId,
    required this.rpName,
    required this.originConfig,
    this.requireUserVerification = false,
    this.challengeTimeout = 300, // 5 минут по умолчанию
    this.tokenLifetime = 3600, // 1 час по умолчанию
    this.scopes = const ['user', 'webauthn.authenticated'],
  });

  /// Проверка origin на соответствие ожидаемому для платформы
  bool validateOrigin(String origin, String platform) {
    return originConfig.isValidOrigin(origin, platform);
  }

  /// Получение ожидаемого origin для платформы
  String getOriginForPlatform(String platform) {
    return originConfig.getOriginForPlatform(platform);
  }

  /// Создает копию объекта с заменой указанных полей
  WebAuthnSettings copyWith({
    String? rpId,
    String? rpName,
    WebAuthnOriginConfig? originConfig,
    bool? requireUserVerification,
    int? challengeTimeout,
    int? tokenLifetime,
    List<String>? scopes,
  }) {
    return WebAuthnSettings(
      rpId: rpId ?? this.rpId,
      rpName: rpName ?? this.rpName,
      originConfig: originConfig ?? this.originConfig,
      requireUserVerification:
          requireUserVerification ?? this.requireUserVerification,
      challengeTimeout: challengeTimeout ?? this.challengeTimeout,
      tokenLifetime: tokenLifetime ?? this.tokenLifetime,
      scopes: scopes ?? this.scopes,
    );
  }
}
