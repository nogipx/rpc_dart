# Система авторизации WebAuthn

## Обзор

Реализована полноценная система проверки прав доступа для всех методов WebAuthn домена. Система обеспечивает безопасность на уровне операций и защищает от несанкционированного доступа к данным пользователей.

## Архитектура

### Основные компоненты

1. **WebAuthnOperation** - enum с типами операций в домене
2. **WebAuthnPermission** - enum с правами доступа
3. **WebAuthnAuthorizationContext** - контекст авторизации пользователя
4. **AuthorizationResult** - результат проверки авторизации
5. **IWebAuthnAuthorizationService** - сервис проверки прав доступа

### Типы операций

```dart
enum WebAuthnOperation {
  // Регистрация
  startRegistration,
  finishRegistration,
  
  // Аутентификация
  startAuthentication,
  finishAuthentication,
  
  // Управление учетными данными
  getUserInfo,
  removeCredential,
  getCredentials,
  
  // Управление токенами и сессиями
  validateToken,
  refreshToken,
  revokeToken,
  isAuthenticated,
  revokeSession,
  revokeAllSessions,
}
```

### Права доступа

```dart
enum WebAuthnPermission {
  // Базовые права пользователя
  manageOwnCredentials,    // Управление своими учетными данными
  manageOwnSessions,       // Управление своими сессиями
  authenticateAsUser,      // Аутентификация как пользователь
  
  // Административные права
  manageAnyCredentials,    // Управление любыми учетными данными
  manageAnySessions,       // Управление любыми сессиями
  viewAnyUserInfo,         // Просмотр информации любого пользователя
  systemAdministration,    // Системное администрирование
}
```

## Логика авторизации

### Пользовательские операции

Для операций с собственными данными требуются базовые права:
- `getUserInfo` (свои данные) → `manageOwnCredentials`
- `removeCredential` (свои данные) → `manageOwnCredentials`
- `revokeSession` (своя сессия) → `manageOwnSessions`

### Административные операции

Для операций с чужими данными требуются административные права:
- `getUserInfo` (чужие данные) → `viewAnyUserInfo`
- `removeCredential` (чужие данные) → `manageAnyCredentials`
- `revokeAllSessions` (чужие сессии) → `manageAnySessions`

### Публичные операции

Не требуют авторизации:
- `startRegistration`
- `finishRegistration`
- `startAuthentication`
- `finishAuthentication`
- `refreshToken` (передает токен в теле запроса и не использует заголовок Authorization)

## Интеграция в Responder

Каждый метод WebAuthnResponder проверяет авторизацию:

```dart
@override
Future<WebAuthnUserInfo> getUserInfo(
  GetUserInfoRequest request, {
  RpcContext? context,
}) async {
  try {
    // Проверяем авторизацию
    await _checkAuthorization(
      operation: WebAuthnOperation.getUserInfo,
      context: context,
      targetUserId: request.userId,
    );

    // Выполняем операцию...
  } catch (e) {
    if (e is RpcException) rethrow;
    throw RpcException('Ошибка при получении информации о пользователе: $e');
  }
}
```

## Извлечение токена

Токен извлекается из HTTP заголовка `Authorization`:

```dart
final authHeader = context?.getHeader('authorization');
String token;
if (authHeader.startsWith('Bearer ')) {
  token = authHeader.substring(7); // Убираем "Bearer "
} else {
  token = authHeader; // Используем как есть
}
```

## Административные права

Пользователи с правом `systemAdministration` автоматически получают доступ ко всем операциям.

## Безопасность

1. **Проверка владения данными** - система проверяет, что пользователь работает только со своими данными
2. **Валидация токенов** - все токены проверяются через ValidateTokenUseCase
3. **Проверка сессий** - дополнительная проверка активности сессий
4. **Blacklist токенов** - поддержка отзыва токенов

## Тестирование

Создан полный набор тестов для проверки логики авторизации:
- Проверка прав доступа
- Определение необходимых прав для операций
- Создание контекстов авторизации
- Обработка результатов авторизации

Запуск тестов:
```bash
dart test test/authorization_test.dart
```

## Использование

### Создание сервиса авторизации

```dart
final authService = WebAuthnAuthorizationService(validateTokenUseCase);
```

### Добавление в WebAuthnResponder

```dart
WebAuthnResponder({
  // ... другие зависимости
  required IWebAuthnAuthorizationService authorizationService,
})
```

### Проверка прав в коде

```dart
final authResult = await authService.checkPermission(
  operation: WebAuthnOperation.removeCredential,
  authContext: authContext,
  targetUserId: 'user123',
);

if (!authResult.isAuthorized) {
  throw RpcException(authResult.errorMessage);
}
```

## Заключение

Система авторизации обеспечивает:
- ✅ Защиту всех методов WebAuthn домена
- ✅ Разделение пользовательских и административных прав
- ✅ Проверку владения данными
- ✅ Интеграцию с системой токенов и сессий
- ✅ Полное тестовое покрытие
- ✅ Соответствие принципам CORD архитектуры 