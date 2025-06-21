# Централизованное управление режимами передачи данных

## Обзор

В контрактах RPC Dart теперь доступна возможность централизованного управления режимами передачи данных через конструктор. Это позволяет задать единую стратегию для всех методов контракта и обеспечивает строгую валидацию соответствия кодеков выбранному режиму.

## Режимы передачи данных

### `RpcDataTransferMode.zeroCopy`
- **Принудительно zero-copy режим**
- Все методы контракта работают без сериализации
- Кодеки НЕ должны передаваться (будет ошибка валидации)
- Работает только с `RpcInMemoryTransport`

```dart
// Responder контракт
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  @override
  void setup() {
    addUnaryMethod<String, String>(
      methodName: 'echo',
      handler: (request, {context}) async => 'Echo: $request',
      // Кодеки НЕ указываем!
    );
  }
}

// Caller контракт
final class MyCaller extends RpcCallerContract {
  MyCaller(RpcCallerEndpoint endpoint) 
      : super('MyService', endpoint, dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  Future<String> echo(String message) {
    return callUnary<String, String>(
      methodName: 'echo',
      request: message,
      // Кодеки НЕ указываем!
    );
  }
}
```

### `RpcDataTransferMode.codec`
- **Принудительно режим сериализации**
- Все методы контракта работают через кодеки
- Кодеки ОБЯЗАТЕЛЬНЫ для всех методов (будет ошибка валидации если не указаны)
- Работает с любыми транспортами

```dart
// Responder контракт
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.codec);
  
  @override
  void setup() {
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      handler: (request, {context}) async => MyResponse('Processed: ${request.data}'),
      requestCodec: MyRequest.codec,   // ← ОБЯЗАТЕЛЬНО
      responseCodec: MyResponse.codec, // ← ОБЯЗАТЕЛЬНО
    );
  }
}

// Caller контракт
final class MyCaller extends RpcCallerContract {
  MyCaller(RpcCallerEndpoint endpoint) 
      : super('MyService', endpoint, dataTransferMode: RpcDataTransferMode.codec);
  
  Future<MyResponse> process(MyRequest request) {
    return callUnary<MyRequest, MyResponse>(
      methodName: 'process',
      request: request,
      requestCodec: MyRequest.codec,   // ← ОБЯЗАТЕЛЬНО
      responseCodec: MyResponse.codec, // ← ОБЯЗАТЕЛЬНО
    );
  }
}
```

### `RpcDataTransferMode.auto` (по умолчанию)
- **Автоматический выбор режима**
- Если кодеки указаны → используется сериализация
- Если кодеки НЕ указаны → используется zero-copy
- Позволяет смешивать режимы в одном контракте
- Валидация: либо оба кодека указаны, либо оба отсутствуют

```dart
// Responder контракт с смешанными режимами
final class MyResponder extends RpcResponderContract {
  MyResponder() : super('MyService', dataTransferMode: RpcDataTransferMode.auto);
  
  @override
  void setup() {
    // Zero-copy метод
    addUnaryMethod<String, String>(
      methodName: 'simpleEcho',
      handler: (request, {context}) async => 'Echo: $request',
      // Кодеки НЕ указаны = zero-copy
    );
    
    // Codec метод
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'complexProcess',
      handler: (request, {context}) async => MyResponse('Result'),
      requestCodec: MyRequest.codec,   // Кодеки указаны = codec
      responseCodec: MyResponse.codec,
    );
  }
}
```

## Валидация

Система автоматически валидирует соответствие переданных кодеков режиму контракта:

### Zero-copy режим
```dart
// ❌ ОШИБКА - кодеки переданы в zero-copy режиме
await caller.callUnary<MyRequest, MyResponse>(
  methodName: 'test',
  request: request,
  requestCodec: codec1,  // ← Ошибка!
  responseCodec: codec2, // ← Ошибка!
);
// Выбросит: "Контракт настроен на принудительный zero-copy режим..."
```

### Codec режим
```dart
// ❌ ОШИБКА - кодеки не переданы в codec режиме
await caller.callUnary<String, String>(
  methodName: 'test',
  request: 'hello',
  // Кодеки отсутствуют в codec режиме - ошибка!
);
// Выбросит: "Контракт настроен на принудительный codec режим..."
```

### Auto режим
```dart
// ❌ ОШИБКА - только один кодек указан
await caller.callUnary<MyRequest, MyResponse>(
  methodName: 'test',
  request: request,
  requestCodec: codec1,  // ← Есть
  // responseCodec отсутствует ← Ошибка!
);
// Выбросит: "В auto режиме либо оба кодека должны быть указаны..."
```

## Преимущества

### 1. **Безопасность типов**
Централизованное управление предотвращает случайные ошибки конфигурации

### 2. **Консистентность**
Все методы контракта используют единый режим передачи данных

### 3. **Явность**
Режим указывается явно в конструкторе, что делает код более читаемым

### 4. **Валидация**
Автоматическая проверка соответствия кодеков выбранному режиму

### 5. **Гибкость**
Auto режим позволяет смешивать подходы когда это оправдано

## Рекомендации

### Используйте `zeroCopy` когда:
- Работаете только с `RpcInMemoryTransport`
- Нужна максимальная производительность
- Данные простые (примитивы, simple objects)

### Используйте `codec` когда:
- Работаете с сетевыми транспортами
- Нужна сериализация данных
- Требуется совместимость с внешними системами

### Используйте `auto` когда:
- Нужна гибкость в выборе режимов
- Разные методы требуют разных подходов
- Миграция между режимами

## Пример полного использования

См. `example/more/contract_modes_example.dart` для детального примера использования всех режимов. 