import '../../../rpc_dart_webauthn.dart';

/// Интерфейс для работы с различными origin в зависимости от платформы клиента
abstract class IOrigin {
  /// Получить origin для указанной платформы
  String getOriginForPlatform(String platform);

  /// Проверить соответствие origin ожидаемому значению для платформы
  bool isValidOrigin(String origin, String platform);
}

/// Конфигурация origin для разных платформ
class WebAuthnOriginConfig implements IOrigin {
  final ProductConfig productConfig;
  final Map<String, String> _customOrigins;
  final String defaultOrigin;

  const WebAuthnOriginConfig({
    required this.productConfig,
    this.defaultOrigin = '',
    Map<String, String>? customOrigins,
  }) : _customOrigins = customOrigins ?? const {};

  /// Получение origin для конкретной платформы
  @override
  String getOriginForPlatform(String platform) {
    switch (platform.toLowerCase()) {
      case 'web':
        return productConfig.webOrigin.toString();
      case 'android':
        return productConfig.androidAppInfo.origin;
      case 'ios':
        return productConfig.iosBundleId;
      case 'default':
        return defaultOrigin;
      default:
        // Проверяем кастомные origins
        if (_customOrigins.containsKey(platform.toLowerCase())) {
          return _customOrigins[platform.toLowerCase()]!;
        }
        return defaultOrigin;
    }
  }

  /// Определяет платформу на основе origin
  String? detectPlatformByOrigin(String origin) {
    final normalizedOrigin = origin.trim();
    if (normalizedOrigin.isEmpty) {
      return null;
    }

    if (normalizedOrigin == productConfig.webOrigin.toString()) {
      return 'web';
    }

    if (normalizedOrigin == productConfig.androidAppInfo.origin) {
      return 'android';
    }

    if (normalizedOrigin == productConfig.iosBundleId) {
      return 'ios';
    }

    for (final entry in _customOrigins.entries) {
      if (entry.value == normalizedOrigin) {
        return entry.key;
      }
    }

    if (defaultOrigin.isNotEmpty && normalizedOrigin == defaultOrigin) {
      return 'default';
    }

    return null;
  }

  /// Проверяет, разрешен ли origin, учитывая платформу
  bool isAllowedOrigin(String origin, {String? platform}) {
    final normalizedOrigin = origin.trim();
    if (normalizedOrigin.isEmpty) {
      return false;
    }

    if (platform != null && platform.isNotEmpty) {
      final expected = getOriginForPlatform(platform);
      if (expected.isEmpty) {
        return false;
      }
      return expected == normalizedOrigin;
    }

    return detectPlatformByOrigin(normalizedOrigin) != null;
  }

  /// Проверка соответствия origin для платформы
  @override
  bool isValidOrigin(String origin, String platform) {
    final expectedOrigin = getOriginForPlatform(platform);
    if (expectedOrigin.isEmpty) {
      return true; // Если нет ожидаемого origin, считаем любой валидным
    }
    return origin == expectedOrigin;
  }

  /// Проверка и выброс исключения если origin невалидный
  void validateOriginOrThrow(String origin, String platform) {
    final expectedOrigin = getOriginForPlatform(platform);
    if (expectedOrigin.isNotEmpty && origin != expectedOrigin) {
      throw WebAuthnException.originMismatch(expectedOrigin, origin);
    }
  }
}
