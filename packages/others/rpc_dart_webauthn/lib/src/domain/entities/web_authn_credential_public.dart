part of '_index.dart';

/// Класс WebAuthnCredential представляет собой модель для хранения учетных данных пользователя WebAuthn.
///
/// Эта сущность хранит информацию о зарегистрированном аутентификаторе пользователя (passkey):
/// идентификаторы, публичный ключ, счетчик для защиты от клонирования и метаданные.
/// Класс реализует иммутабельный подход - все поля финальные, изменения создают новые экземпляры.
///
/// Основное назначение:
/// * Хранение учетных данных пользователя в репозитории
/// * Проверка аутентификации при последующих входах пользователя
/// * Защита от клонирования через отслеживание счетчика подписи
class WebAuthnCredentialPublic implements IRpcSerializable {
  /// Уникальный идентификатор записи учетных данных
  final String id;

  /// Уникальный идентификатор учетных данных (credentialId из WebAuthn спецификации)
  /// Используется для поиска ключа при последующих аутентификациях
  final String credentialId;

  /// Идентификатор пользователя, которому принадлежат эти учетные данные
  /// Обычно содержит никнейм или другой уникальный идентификатор пользователя
  final String userId;

  /// Дата и время создания учетных данных
  final DateTime createdAt;

  /// Создает новый экземпляр учетных данных WebAuthn
  ///
  /// Требует все необходимые поля для функционирования системы безопасности WebAuthn
  const WebAuthnCredentialPublic({
    required this.id,
    required this.credentialId,
    required this.userId,
    required this.createdAt,
  });

  /// Создает экземпляр WebAuthnCredential из JSON объекта
  ///
  /// Используется для десериализации данных из хранилища.
  /// Автоматически декодирует публичный ключ из Base64 формата.
  factory WebAuthnCredentialPublic.fromJson(Map<String, dynamic> json) {
    return WebAuthnCredentialPublic(
      id: json['id'],
      credentialId: json['credentialId'],
      userId: json['userId'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }

  /// Конвертирует учетные данные в JSON формат для сериализации
  ///
  /// Кодирует публичный ключ в Base64 формат для безопасного хранения
  @override
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'credentialId': credentialId,
      'userId': userId,
      'createdAt': createdAt.toUtc().toIso8601String(),
    };
  }

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnCredentialPublic> get codec =>
      RpcCodec(WebAuthnCredentialPublic.fromJson);

  /// Создает копию объекта с обновленными полями
  ///
  /// Позволяет изменять любое поле учетных данных, сохраняя иммутабельность.
  /// Поля, не указанные в параметрах, сохраняют исходные значения.
  WebAuthnCredentialPublic copyWith({
    String? id,
    String? credentialId,
    String? userId,
    DateTime? createdAt,
  }) {
    return WebAuthnCredentialPublic(
      id: id ?? this.id,
      credentialId: credentialId ?? this.credentialId,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
