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
class WebAuthnCredentialPrivate extends WebAuthnCredentialPublic
    implements IRpcSerializable {
  /// Публичный ключ аутентификатора в бинарном формате
  /// Используется для проверки подписи при аутентификации
  final List<int> publicKey;

  /// Счетчик подписи для защиты от клонирования
  /// Увеличивается при каждой успешной аутентификации
  final int counter;

  /// Создает новый экземпляр учетных данных WebAuthn
  ///
  /// Требует все необходимые поля для функционирования системы безопасности WebAuthn
  const WebAuthnCredentialPrivate({
    required super.id,
    required super.credentialId,
    required super.userId,
    required this.publicKey,
    required this.counter,
    required super.createdAt,
  });

  /// Создает экземпляр WebAuthnCredential из JSON объекта
  ///
  /// Используется для десериализации данных из хранилища.
  /// Автоматически декодирует публичный ключ из Base64 формата.
  factory WebAuthnCredentialPrivate.fromJson(Map<String, dynamic> json) {
    return WebAuthnCredentialPrivate(
      id: json['id'],
      credentialId: json['credentialId'],
      userId: json['userId'],
      publicKey: WebAuthnSafeBase64.decode(json['publicKey']),
      counter: json['counter'],
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
      'publicKey': WebAuthnSafeBase64.encode(publicKey),
      'counter': counter,
      'createdAt': createdAt.toUtc().toIso8601String(),
    };
  }

  /// RPC Codec для сериализации/десериализации
  static RpcCodec<WebAuthnCredentialPrivate> get codec =>
      RpcCodec(WebAuthnCredentialPrivate.fromJson);

  WebAuthnCredentialPublic get public => WebAuthnCredentialPublic(
    id: id,
    credentialId: credentialId,
    userId: userId,
    createdAt: createdAt,
  );

  /// Создает копию объекта с обновленными полями
  ///
  /// Позволяет изменять любое поле учетных данных, сохраняя иммутабельность.
  /// Поля, не указанные в параметрах, сохраняют исходные значения.
  @override
  WebAuthnCredentialPrivate copyWith({
    String? id,
    String? credentialId,
    String? userId,
    List<int>? publicKey,
    int? counter,
    DateTime? createdAt,
  }) {
    return WebAuthnCredentialPrivate(
      id: id ?? this.id,
      credentialId: credentialId ?? this.credentialId,
      userId: userId ?? this.userId,
      publicKey: publicKey ?? this.publicKey,
      counter: counter ?? this.counter,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Специализированный метод для создания копии с обновленным счетчиком
  ///
  /// Используется при успешной аутентификации для обновления счетчика,
  /// что обеспечивает защиту от клонирования аутентификаторов.
  WebAuthnCredentialPrivate copyWithCounter(int newCounter) {
    return copyWith(counter: newCounter);
  }
}
