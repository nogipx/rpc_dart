import 'dart:convert';
import '../../rpc_dart_webauthn.dart';
import 'package:uuid/uuid.dart';
import 'package:paseto_dart/paseto_dart.dart';

/// Сервис для работы с PASETO токенами
class PasetoUtils {
  /// Секретный ключ для шифрования токенов
  final SecretKey _secretKey;

  /// Версия PASETO протокола
  final Version _version;

  /// Время жизни токена в секундах (по умолчанию 1 час)
  final int _tokenLifetime;

  /// Конструктор
  PasetoUtils({
    required List<int> secretKeyBytes,
    Version version = Version.v4,
    int tokenLifetime = 3600,
  })  : _secretKey = SecretKeyData(secretKeyBytes),
        _version = version,
        _tokenLifetime = tokenLifetime;

  /// Создает PASETO токен с указанным контентом
  Future<String> createToken({
    required String userId,
    required List<String> scopes,
    Map<String, dynamic>? extra,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final expireAt = now + _tokenLifetime;

    final payload = PasetoTokenPayload(
      sub: userId,
      exp: expireAt,
      iat: now,
      jti: const Uuid().v4(),
      scopes: scopes,
      extra: extra,
    );

    // Шифруем контент в PASETO сообщение
    final message = await Message.encryptString(
      jsonEncode(payload.toJson()),
      version: _version,
      secretKey: _secretKey,
    );

    // Получаем строку токена
    return message.toToken.toTokenString;
  }

  /// Проверяет и декодирует PASETO токен
  Future<PasetoTokenPayload?> validateToken(String tokenString) async {
    // Парсим строку токена
    final token = await Token.fromString(tokenString);

    // Расшифровываем сообщение
    final message = await token.decryptLocalMessage(secretKey: _secretKey);

    // Получаем JSON из сообщения
    final jsonContent = message.jsonContent;

    // Проверяем срок действия токена
    final exp = jsonContent?['exp'] as int?;
    if (exp == null) {
      throw Exception('Токен не содержит время истечения (exp)');
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (now > exp) {
      throw Exception('Токен истек');
    }

    // Преобразуем JSON в модель
    return PasetoTokenPayload.fromJson(jsonContent ?? {});
  }
}
