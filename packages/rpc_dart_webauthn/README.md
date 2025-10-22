# rpc_dart_webauthn

`rpc_dart_webauthn` предоставляет полностью типизированный WebAuthn-домен для экосистемы
[`rpc_dart`](https://pub.dev/packages/rpc_dart). Пакет реализует полный цикл регистрации и
аутентификации passkey-учетных данных, управление сессиями и PASETO-токенами и соблюдает ключевые
требования спецификации W3C WebAuthn Level 3.

## Возможности

- ⚙️ **Полное соответствие спецификации:** сервер проверяет таймаут challenge, сверяет origin по
  настройкам продукта, проверяет флаги UP/UV, счетчики и user handle для защиты от
  клонирования устройств.
- 🔐 **Управление токенами и сессиями:** встроенная генерация и валидация PASETO-токенов,
  отзыв отдельных сессий и глобальный отзыв для пользователя.
- 🧩 **Расширяемая архитектура:** use case-ориентированный домен легко интегрируется с любым RPC
  транспортом (`rpc_dart_transports`, in-memory, isolate и т.д.).
- 🌐 **Поддержка продуктовых платформ:** единая конфигурация для web, Android (через Digital Asset
  Links) и iOS (apple-app-site-association) с опциональным `.well-known` HTTP сервером.

## Установка

```yaml
dependencies:
  rpc_dart_webauthn: ^1.0.0
  rpc_dart: ^2.3.1
  rpc_dart_transports: ^1.4.0
```

Выполните `dart pub get`, чтобы подтянуть зависимости.

## Настройка домена

Основная конфигурация выполняется через `WebAuthnDomainConfig`. Укажите RP ID, origin и продуктовые
параметры:

```dart
final domainConfig = WebAuthnDomainConfig.production(
  rpId: 'example.com',
  rpName: 'Example Passkeys',
  webOrigin: Uri.parse('https://example.com'),
  androidAppInfo: const ProductConfigAndroid(
    packageName: 'com.example.passkeys',
    sha256: '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00',
  ),
  iosBundleId: 'TEAMID.com.example.passkeys',
  secretKey: secure32ByteKeyFromVault,
);
```

> 💡 Для разработки используйте `WebAuthnDomainConfig.inMemory(...)`: он подставит безопасные
> значения по умолчанию и может поднять встроенный `.well-known` сервер.

## Запуск респондера поверх HTTP/2

Пакет `rpc_dart_transports` предоставляет `RpcHttp2Server`, который можно использовать совместно с
`WebAuthnResponder`. Ниже пример инициализации общего респондера и регистрации его на HTTP/2
сервере:

```dart
final webAuthnRepository = MemoryWebAuthnRepositoryImpl();
final challengeRepository = MemoryChallengeRepositoryImpl();
final sessionRepository = MemorySessionRepositoryImpl();
final tokenBlacklistRepository = MemoryTokenBlacklistRepositoryImpl();

final settings = WebAuthnSettings(
  rpId: domainConfig.rpId,
  rpName: domainConfig.rpName,
  originConfig: WebAuthnOriginConfig(
    productConfig: ProductConfig(
      webOrigin: domainConfig.webOrigin,
      androidAppInfo: domainConfig.androidAppInfo!,
      iosBundleId: domainConfig.iosBundleId!,
    ),
    defaultOrigin: domainConfig.webOrigin.toString(),
  ),
  requireUserVerification: domainConfig.requireUserVerification,
  challengeTimeout: domainConfig.challengeTimeout,
  tokenLifetime: domainConfig.tokenLifetime,
);

final paseto = PasetoUtils(secretKeyBytes: domainConfig.secretKey!);

final responder = WebAuthnResponder(
  startRegistrationUseCase: StartRegistrationUseCase(
    challengeRepository,
    settings: settings,
  ),
  finishRegistrationUseCase: FinishRegistrationUseCase(
    webAuthnRepository,
    challengeRepository,
    settings: settings,
  ),
  startAuthenticationUseCase: StartAuthenticationUseCase(
    webAuthnRepository,
    challengeRepository,
    settings: settings,
  ),
  finishAuthenticationUseCase: FinishAuthenticationUseCase(
    webAuthnRepository,
    challengeRepository,
    sessionRepository,
    settings: settings,
    pasetoUtils: paseto,
  ),
  validateTokenUseCase: ValidateTokenUseCase(
    webAuthnRepository,
    sessionRepository,
    tokenBlacklistRepository,
    paseto,
  ),
  revokeSessionUseCase: RevokeSessionUseCase(sessionRepository),
  webAuthnRepository: webAuthnRepository,
  settings: settings,
  authorizationService: WebAuthnAuthorizationService(
    ValidateTokenUseCase(
      webAuthnRepository,
      sessionRepository,
      tokenBlacklistRepository,
      paseto,
    ),
  ),
);

final server = RpcHttp2Server.createWithContracts(
  host: '0.0.0.0',
  port: 9443,
  contracts: [responder],
);
await server.start();
```

- Репозитории можно заменить на собственные реализации (`IWebAuthnRepository`,
  `IChallengeRepository`, `ISessionRepository`, `ITokenBlacklistRepository`), если необходимо
  постоянное хранилище.
- При включенном `domainConfig.serverConfig` запускается вспомогательный HTTP сервер, отдающий
  `.well-known/assetlinks.json` и `apple-app-site-association`.

## Клиентская интеграция

На стороне клиента используйте `WebAuthnCaller` и транспорт из `rpc_dart_transports`:

```dart
final transport = await RpcHttp2CallerTransport.secureConnect(
  host: 'example.com',
  port: 9443,
  trustedCertificateBytes: myCaCertificate,
);

final callerEndpoint = RpcCallerEndpoint(transport: transport);
final webAuthnCaller = WebAuthnCaller(callerEndpoint);

final startRegistration = await webAuthnCaller.startRegistration(
  StartRegistrationParams(
    userId: 'user-123',
    username: 'user@example.com',
    displayName: 'Example User',
  ),
);
```

`StartRegistrationParams` теперь позволяет передать `username`, `displayName` и произвольный
`userHandle`. Полученные `RegistrationOptions` содержат корректно закодированный user handle и
настройки аутентификатора (включая `requireUserVerification` при необходимости).

После получения ответа от браузера/платформы вызовите:

```dart
await webAuthnCaller.finishRegistration(
  FinishRegistrationParams(
    userId: 'user-123',
    origin: 'https://example.com',
    platform: 'web',
    credential: registrationCredentialFromClient,
  ),
);
```

Для аутентификации используется аналогичная пара `startAuthentication` / `finishAuthentication`. В
финальном вызове обязательно передавайте `platform` (`web`, `android`, `ios`) — сервер сверит origin
с конфигурацией и проверит user handle.

## Типичный сценарий

1. **Регистрация:**
   - `startRegistration` генерирует challenge, сохраняет его с учетом таймаута, возвращает
     `RegistrationOptions` с user handle в формате base64url.
   - Клиент выполняет `navigator.credentials.create` и передает результат в `finishRegistration`.
   - Сервер проверяет подпись attestation, origin, наличие UP/UV флагов и сохраняет credential.
2. **Аутентификация:**
   - `startAuthentication` возвращает `AuthenticationOptions` с allowCredentials и таймаутом из
     настроек.
   - `finishAuthentication` валидирует challenge, origin, user handle, счетчики, генерирует PASETO
     токен и сохраняет сессию.
3. **Интеграция с другим сервисом:**
   - Сервис получает PASETO из заголовка `Authorization: Bearer <token>` и, прежде чем доверять
     данным, обращается к `validateToken`. Ответ содержит `WebAuthnCredentialPublic` и
     `WebAuthnAuthContext`, которые можно использовать для авторизационных решений без знания
     внутренних структур токена.
   - `validateToken` гарантирует, что токен не просрочен, не отозван и не попал в blacklist.
     Если раздавать секретный ключ другим сервисам нежелательно, это основной способ проверки.
     Расшаривание ключа допустимо только в закрытых контурах, и даже тогда сервисам всё равно
     понадобится ходить в домен за информацией о blacklist/сессиях.
   - Для обновления токена без повторного прохода WebAuthn используйте `refreshToken` — метод
     повторно выпускает PASETO с новым `jti`, переносит `sessionId` и продлевает срок действия
     сессии. Старый токен автоматически добавляется в blacklist.
   - Для отзыва токенов доступны `revokeSession` и `revokeAllSessions`.

### Использование токена в микросервисной архитектуре

1. **Передача** – клиенты отправляют полученный PASETO как bearer-токен (обычно заголовок
   `Authorization`). Сервисы-агрегаторы могут проксировать его дальше по цепочке.
2. **Валидация** – рекомендуется централизованно вызывать `validateToken`: только домен знает о
   blacklist и состоянии сессий, поэтому он вернет как публичные данные credential, так и
   актуальный auth-контекст. Если архитектура допускает локальную валидацию, сервисам необходимо
   хранить тот же секрет, но даже в этом случае для проверки отзыва потребуется вызывать домен.
3. **Продление** – перед истечением срока клиент вызывает `refreshToken` и получает новый PASETO с
   тем же `sessionId`. Старый `jti` уже в blacklist, поэтому его можно удалить из хранилища.
4. **Дальнейшая работа** – downstream-сервисы могут использовать `sessionId`, `scopes` и
   возвращаемый контекст для принятия решений или кэширования, полагаясь на домен WebAuthn как на
   источник истины.

## Жизненный цикл PASETO-токена

1. **Выпуск токена**
   - `finishAuthentication` создает PASETO при успешном assertion.
   - Срок жизни (`expiresIn`) берется из `WebAuthnSettings.tokenLifetime` и синхронно сохраняется в
     сессии (`ISessionRepository`).
   - В payload токена помещаются `sessionId` и публичная часть credential — другие сервисы могут
     их использовать для авторизационных решений.

2. **Проверка токена внешними сервисами**
   - Любой сервис, имеющий доступ к домену, вызывает `validateToken` и получает
     `WebAuthnCredentialPublic` и `WebAuthnAuthContext`.
   - `validateToken` проверяет срок действия, удостоверяется, что `jti` не находится в blacklist,
     и что связанная сессия активна.

3. **Обновление токена**
   - Клиент передает действующий токен в `refreshToken`.
   - Use case проверяет токен, гарантирует активность сессии, помещает прежний `jti` в blacklist и
     продлевает срок жизни сессии.
   - Возвращается `AuthResponse` с новым PASETO; новый токен содержит прежний `sessionId` и набор
     скопов (или их подмножество, если запросить более узкий набор через `requestedScopes`).

4. **Отзыв токена**
   - `revokeSession` или `revokeAllSessions` помечают сессии как неактивные.
   - Дополнительно можно вручную добавить `jti` в blacklist через `ITokenBlacklistRepository`.

### Пример обновления токена на клиенте

```dart
final refreshResult = await webAuthnCaller.refreshToken(
  const RefreshTokenParams(token: currentAccessToken),
);

if (!refreshResult.success) {
  // Повторно запустить WebAuthn поток
}

final newToken = refreshResult.authResponse!.accessToken;
```

> 💡 После успешного обновления сохраните новый токен, а старый можно удалить из хранилища клиента —
> домен уже поместил его `jti` в blacklist.

### Почему возвращается только один токен

`AuthResponse` содержит единственный PASETO access token. Отдельный «refresh token» не требуется: метод
`refreshToken` принимает текущий access token, проверяет его подпись, состояние сессии, добавляет старый
`jti` в blacklist и возвращает новый PASETO с продлённым сроком жизни. Благодаря этому клиентам достаточно
хранить только актуальный bearer-токен, а устаревшие экземпляры автоматически блокируются при ротации.

### Клиентский interceptor для автоматического обновления токена

Чтобы не прокидывать заголовок авторизации вручную и автоматически реагировать на истечение срока, подключите
`WebAuthnTokenInterceptor` к `RpcCallerEndpoint`:

```dart
final tokenStore = MySecureStore();

callerEndpoint.addInterceptor(
  WebAuthnTokenInterceptor(
    tokenProvider: tokenStore.readToken,
    refreshCallback: (token, call) async {
      final result = await webAuthnCaller.refreshToken(
        RefreshTokenParams(token: token),
      );

      return result.authResponse;
    },
    onTokenRefreshed: (state, response) => tokenStore.save(state),
  ),
);
```

Interceptor добавляет заголовок `Authorization: Bearer <token>` ко всем вызовам, проактивно обновляет PASETO,
если до истечения срока осталось меньше заданного порога, и повторяет запрос при ошибке авторизации, получив
новый токен через `refreshToken`. Колбэки `tokenProvider` и `onTokenRefreshed` можно связать с безопасным
хранилищем приложения, а `refreshCallback` — с любым `IWebAuthnContract`-клиентом.

## Тестирование

Пакет содержит тестовые векторы W3C и сценарии use case'ов. Запустите все проверки командой:

```bash
dart test
```

Это гарантирует, что изменения не нарушают спецификацию WebAuthn и внутренние инварианты домена.
