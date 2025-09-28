# Шифрованный транспорт на базе Licensify

Ниже описан обновлённый слой защищённого транспорта, который использует пакет
[`licensify`](https://pub.dev/packages/licensify). Licensify инкапсулирует
сообщения рукопожатия в токены PASETO v4 и гарантирует их подлинность, поэтому
нам не нужно поддерживать собственную схему подписей. Слой оформлен как
адаптер поверх любого транспорта: caller и responder автоматически договариваются
о ключах, а каждый фрейм шифруется с помощью AEAD без правок существующих
реализаций транспортов.

## Цели

- **Композиционность** – зашифрованный слой оборачивает любой транспорт через
  `SecureTransportAdapter`, не требуя правок конструкторов.
- **Минимум настроек** – эндпоинты хранят только долгосрочные ключи подписей,
  а все сессионные данные обмениваются через токены Licensify при запуске.
- **Прямая секретность** – сессионные ключи выводятся из одноразовых
  случайных значений и уничтожаются после ротации.
- **Независимость от транспорта** – требуется лишь упорядоченная доставка
  сообщений, что подходит для HTTP/2, WebSocket, isolates, TURN и т. д.

## Зависимости и ключи

1. Добавьте Licensify в пакеты, где создаются транспорты:

   ```dart
   dependencies:
     licensify: ^3.1.0
   ```

2. Сгенерируйте долгосрочную пару ключей и сохраните её рядом с конфигурацией
   эндпоинта:

   ```dart
   final keys = await Licensify.generateSigningKeys();
   await savePrivateKey(keys.privateKeyBytes);
   await savePublicKey(keys.publicKeyBytes);
   ```

   Публичный ключ публикуется во внешнем каталоге/конфигурации, приватный
   остаётся только на узле.

## Рукопожатие на токенах Licensify

Рукопожатие проходит по управляющему потоку `0` до начала обмена RPC. Каждое
сообщение — токен Licensify с временем жизни пять минут, чтобы исключить
повторные атаки.

```text
Caller                                      Responder
------                                      ---------
Долгосрочный ключ KC                        Долгосрочный ключ KR
Общие публичные ключи Pc, Pr                Общие публичные ключи Pc, Pr

1. SecureHello = Licensify.createLicense(
     privateKey: KC.priv,
     appId: 'rpc.secure',
     expirationDate: now + 5 minutes,
     type: LicenseType.standard,
     features: {
       'protocol': 'rpc+secure/1',
       'nonce': base64(nc),
     },
     metadata: {
       'seed': base64(sc),          // 32 случайных байта
       'transportId': callerTransportId,
     },
   )
   ->
                                             проверить подпись через Pc
                                             извлечь `sc`, `nc`
                                             hc = HKDF(sc || nc, 'rpc:handshake:caller')
                                             выбрать sr (32 случайных байта) и nr
                                             SecureAck = Licensify.createLicense(
                                               privateKey: KR.priv,
                                               appId: 'rpc.secure',
                                               expirationDate: now + 5 minutes,
                                               type: LicenseType.standard,
                                               features: {
                                                 'protocol': 'rpc+secure/1',
                                                 'nonce': base64(nr),
                                               },
                                               metadata: {
                                                 'seed': base64(sr),
                                                 'peerNonce': base64(nc),
                                               },
                                             )
2. <- SecureAck
   проверить подпись через Pr
   убедиться, что `metadata.peerNonce == nc`
   hr = HKDF(sc || sr || nr, 'rpc:handshake:responder')

3. После валидации обе стороны получают финальные сессионные ключи:
   sendKeyBytes = HKDF(sc || sr || nc || nr, 'rpc:data:send' || role)
   recvKeyBytes = HKDF(sc || sr || nc || nr, 'rpc:data:recv' || role)
   sendKey = Licensify.encryptionKeyFromBytes(sendKeyBytes)
   recvKey = Licensify.encryptionKeyFromBytes(recvKeyBytes)
```

- Licensify гарантирует подлинность сообщений `SecureHello` и `SecureAck`.
- Случайные nonce связывают ответы с исходным запросом и защищают от повторов.
- Данные рукопожатия затираются из памяти после вывода сессионных ключей.

## Защита фреймов

Каждый последующий фрейм упаковывается в токен PASETO v4.local. Адаптер ведёт
монотонный счётчик `sequence` для каждого направления, кодирует оригинальный
фрейм в Base64 и передаёт его в Licensify, который сам управляет nonce и тегами
целостности. Значение `handshakeTranscriptHash` — это дайджест, покрывающий оба
токена рукопожатия (например, `SHA256(SecureHello || SecureAck)`), чтобы фреймы
криптографически привязывались к согласованной сессии:

```dart
final frameBytes = codec.encode(originalFrame);
final assertion = base64Encode(handshakeTranscriptHash);
final token = await Licensify.encryptData(
  data: {
    'payload': base64Encode(frameBytes),
    'transportId': transportId,
    'streamId': streamId,
    'protocol': 'rpc+secure/1',
    'sequence': sequence,
  },
  encryptionKey: sendKey,
  implicitAssertion: assertion,
);
```

- На провод уходит строковый токен вместо исходных байт фрейма. Инварианты
  (`transportId`, версия протокола, stream ID, sequence) передаются внутри токена,
  чтобы принимающая сторона могла их проверить до декодирования полезной
  нагрузки.
- На приёме вызывается `await Licensify.decryptData` с тем же `recvKey` и
  `implicitAssertion`. Если проверка подписи или метаданных не проходит, фрейм
  отвергается и соединение закрывается как небезопасное.
- Успешная расшифровка возвращает `Map<String, dynamic>`; полезная нагрузка
  восстанавливается обратным преобразованием Base64:

  ```dart
  final decoded = await Licensify.decryptData(
    encryptedToken: token,
    encryptionKey: recvKey,
    implicitAssertion: assertion,
  );
  final restoredFrame = codec.decode(base64Decode(decoded['payload'] as String));
  ```
- После завершения сессии освободите симметричные ключи вызовами
  `sendKey.dispose()` / `recvKey.dispose()`, чтобы стереть их из памяти.

## Ротация ключей

- Сессионные ключи истекают по таймеру (по умолчанию 12 часов) или количеству
  фреймов. Повторное рукопожатие запускается на управляющем потоке, пока
  пользовательские стримы приостановлены.
- Для смены идентичностей публикуйте новый публичный ключ Licensify и храните
  предыдущие в кэше на время миграции. Как только peer принимает новый ключ,
  защищённый канал продолжает работу без разрыва.

## Шаги реализации

1. Добавьте связку `SecureChannelNegotiator` и `SecureTransportAdapter`, которая
   завершает рукопожатие и оборачивает фреймы после успешной валидации Licensify.
2. Напишите тесты:
   - успешное рукопожатие для каждого транспорта;
   - отказ при проверке токена с неподходящим публичным ключом;
   - повторное рукопожатие после ротации ключей.
3. Собирайте метрики: длительность рукопожатия, число отказов, ошибки фреймов,
   количество ротаций.

## Использование

```dart
final baseCaller = await RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);
final secureCaller = SecureTransportAdapter.wrap(
  baseCaller,
  keyStore: callerKeyStore,
);

final baseResponder = RpcWebSocketResponderTransport(channel);
final secureResponder = SecureTransportAdapter.wrap(
  baseResponder,
  keyStore: responderKeyStore,
);
```

После обёртки транспорт автоматически запускает рукопожатие на Licensify и
предоставляет аутентифицированный зашифрованный канал до начала RPC. Один и тот
же адаптер подходит для каналов isolate, HTTP/2, WebSocket и собственных
реализаций транспорта.
