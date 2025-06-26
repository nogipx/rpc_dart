# Гибкое использование кодеков в RPC контрактах

## 🎯 Новая функциональность

Теперь вы можете **указать кодеки в любом режиме**, но система автоматически определит, использовать их или игнорировать для максимальной производительности.

## 💡 Ключевые преимущества

- ✅ **Гибкость**: Можно указать кодеки "на всякий случай"
- ✅ **Производительность**: В zero-copy режиме кодеки игнорируются автоматически
- ✅ **Простота**: Один и тот же код работает в разных режимах
- ✅ **Безопасность**: Валидация предотвращает ошибки конфигурации

## 📋 Режимы работы

### 1. ZeroCopy режим (принудительный)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.zeroCopy);
  
  @override
  void setup() {
    // ✅ Кодеки указаны, но будут проигнорированы для производительности
    addUnaryMethod<String, String>(
      methodName: 'echo',
      requestCodec: myStringCodec,  // 👈 Проигнорирован
      responseCodec: myStringCodec, // 👈 Проигнорирован
      handler: (request, {context}) => Future.value('Echo: $request'),
    );
  }
}
```

### 2. Codec режим (принудительный)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.codec);
  
  @override
  void setup() {
    // ✅ Кодеки ОБЯЗАТЕЛЬНЫ и используются для сериализации
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      requestCodec: myRequestCodec,  // ← Обязательно!
      responseCodec: myResponseCodec, // ← Обязательно!
      handler: (request, {context}) => processRequest(request),
    );
  }
}
```

### 3. Auto режим (автоматический)
```dart
class MyContract extends RpcResponderContract {
  MyContract() : super('MyService', dataTransferMode: RpcDataTransferMode.auto);
  
  @override
  void setup() {
    // Zero-copy метод (кодеки не указаны)
    addUnaryMethod<String, String>(
      methodName: 'fastEcho',
      handler: (request, {context}) => Future.value('Fast: $request'),
    );
    
    // Codec метод (кодеки указаны)
    addUnaryMethod<MyRequest, MyResponse>(
      methodName: 'process',
      requestCodec: myRequestCodec,
      responseCodec: myResponseCodec,
      handler: (request, {context}) => processRequest(request),
    );
  }
}
```

## 🔧 Техническая реализация

### Как это работает

1. **Определение режима**: Система анализирует `dataTransferMode` контракта
2. **Получение эффективных кодеков**: Вызывается `_getEffectiveCodecs()`
3. **Применение логики**:
   - `zeroCopy` режим → кодеки обнуляются (`null`)
   - `codec` режим → кодеки используются как есть
   - `auto` режим → зависит от наличия кодеков

### Методы реализации

```dart
// Определяет режим на основе настроек контракта
bool _determineTransferMode<TRequest, TResponse>(
  IRpcCodec<TRequest>? requestCodec,
  IRpcCodec<TResponse>? responseCodec,
) {
  switch (dataTransferMode) {
    case RpcDataTransferMode.zeroCopy:
      return true; // Всегда zero-copy
    case RpcDataTransferMode.codec:
      return false; // Всегда codec
    case RpcDataTransferMode.auto:
      return requestCodec == null && responseCodec == null; // Авто
  }
}

// Возвращает фактически используемые кодеки
(IRpcCodec<TRequest>?, IRpcCodec<TResponse>?) _getEffectiveCodecs<TRequest, TResponse>(
  IRpcCodec<TRequest>? requestCodec,
  IRpcCodec<TResponse>? responseCodec,
) {
  final isZeroCopy = _determineTransferMode(requestCodec, responseCodec);
  
  if (isZeroCopy) {
    return (null, null); // Игнорировать кодеки
  } else {
    return (requestCodec, responseCodec); // Использовать кодеки
  }
}
```

## ⚠️ Валидация

### Codec режим
- **Требует**: Оба кодека (request + response)
- **Ошибка**: Если какой-то кодек отсутствует

### Auto режим  
- **Для codec**: Требует оба кодека или ни одного
- **Ошибка**: Если указан только один кодек

### ZeroCopy режим
- **Разрешает**: Любые кодеки (игнорируются)
- **Оптимизация**: Автоматическое обнуление для производительности

## 🚀 Примеры использования

### Универсальный контракт
```dart
class UniversalContract extends RpcResponderContract {
  UniversalContract({
    required RpcDataTransferMode mode,
  }) : super('UniversalService', dataTransferMode: mode);
  
  @override
  void setup() {
    // Один и тот же код работает во всех режимах!
    addUnaryMethod<String, String>(
      methodName: 'echo',
      requestCodec: stringCodec,  // Используется в codec, игнорируется в zeroCopy
      responseCodec: stringCodec,
      handler: (request, {context}) => Future.value('Echo: $request'),
    );
  }
}

// Использование:
final zeroCopyContract = UniversalContract(mode: RpcDataTransferMode.zeroCopy);
final codecContract = UniversalContract(mode: RpcDataTransferMode.codec);
```

### Клиентские контракты
```dart
class FlexibleClient extends RpcCallerContract {
  FlexibleClient(RpcCallerEndpoint endpoint, {
    RpcDataTransferMode mode = RpcDataTransferMode.auto,
  }) : super('MyService', endpoint, dataTransferMode: mode);

  Future<String> echo(String message) {
    return callUnary<String, String>(
      methodName: 'echo',
      request: message,
      requestCodec: stringCodec,  // Игнорируется в zeroCopy
      responseCodec: stringCodec, // Игнорируется в zeroCopy
    );
  }
}
```

## 📊 Производительность

| Режим | Кодеки | Сериализация | Производительность |
|-------|--------|--------------|-------------------|
| `zeroCopy` | Указаны | ❌ Игнорируется | 🚀 Максимальная |
| `codec` | Указаны | ✅ Используется | 📦 Стандартная |
| `auto` | Не указаны | ❌ Zero-copy | 🚀 Максимальная |
| `auto` | Указаны | ✅ Codec | 📦 Стандартная |

## 🎉 Заключение

Новая система обеспечивает **максимальную гибкость** при сохранении **типовой безопасности** и **производительности**. Вы можете писать универсальный код, который адаптируется к различным условиям выполнения. 