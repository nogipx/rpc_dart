# Концепция: Byte Serialization для RPC Dart

## Проблема с текущим подходом

Сейчас все сообщения обязаны реализовывать `toJson()`, что создает накладные расходы:

```dart
// Текущий подход
abstract interface class IRpcSerializableMessage {
  Map<String, dynamic> toJson(); // ❌ Всегда через JSON
}

// Для protobuf это неэффективно:
class RpcUser implements IRpcSerializableMessage {
  final User _proto;
  
  @override
  Map<String, dynamic> toJson() {
    // ❌ protobuf -> JSON -> Map -> JSON string -> UTF8 bytes
    return {
      'id': _proto.id,
      'name': _proto.name,
      // ...
    };
  }
}
```

## Предлагаемое решение

Заменить `toJson()` на прямую сериализацию в байты:

```dart
/// НОВЫЙ ИНТЕРФЕЙС
abstract interface class IRpcSerializableMessage {
  /// Прямая сериализация в байты
  Uint8List serialize();
}

/// Функция десериализации (вместо статических методов)
typedef RpcDeserializer<T extends IRpcSerializableMessage> = T Function(Uint8List bytes);
```

## Примеры реализаций

### 1. Protobuf реализация (максимальная эффективность)

```dart
class RpcUser implements IRpcSerializableMessage {
  final User _proto; // Generated protobuf class
  
  RpcUser(this._proto);
  
  factory RpcUser.create({
    required int id,
    required String name,
    required String email,
  }) {
    final proto = User()
      ..id = id
      ..name = name
      ..email = email;
    return RpcUser(proto);
  }
  
  @override
  Uint8List serialize() {
    // ✅ Прямая сериализация! protobuf -> bytes
    return _proto.writeToBuffer();
  }
  
  static RpcUser deserialize(Uint8List bytes) {
    // ✅ Прямая десериализация! bytes -> protobuf
    final proto = User.fromBuffer(bytes);
    return RpcUser(proto);
  }
  
  // Геттеры для удобного доступа
  int get id => _proto.id;
  String get name => _proto.name;
  String get email => _proto.email;
}
```

### 2. JSON реализация (обратная совместимость)

```dart
class RpcString implements IRpcSerializableMessage {
  final String value;
  
  RpcString(this.value);
  
  @override
  Uint8List serialize() {
    // JSON для простых типов и обратной совместимости
    final json = jsonEncode({'value': value});
    return Uint8List.fromList(utf8.encode(json));
  }
  
  static RpcString deserialize(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    return RpcString(json['value']);
  }
}
```

### 3. MessagePack реализация (компактность)

```dart
// Гипотетический пример с msgpack
class RpcCompactMessage implements IRpcSerializableMessage {
  final Map<String, dynamic> data;
  
  RpcCompactMessage(this.data);
  
  @override
  Uint8List serialize() {
    // Компактная бинарная сериализация
    return msgpack.encode(data);
  }
  
  static RpcCompactMessage deserialize(Uint8List bytes) {
    final data = msgpack.decode(bytes);
    return RpcCompactMessage(data);
  }
}
```

## Упрощенный сериализатор

```dart
class RpcSerializer<T extends IRpcSerializableMessage> implements IRpcSerializer<T> {
  final RpcDeserializer<T> _deserializer;

  RpcSerializer({required RpcDeserializer<T> deserializer}) 
    : _deserializer = deserializer;

  @override
  Uint8List serialize(T message) {
    // ✅ Прямой вызов! Никаких промежуточных слоев!
    return message.serialize();
  }

  @override
  T deserialize(Uint8List bytes) {
    // ✅ Прямой вызов! Никаких промежуточных слоев!
    return _deserializer(bytes);
  }
}
```

## Использование в endpoint

```dart
class RpcEndpoint {
  // Регистрация с новым сериализатором
  void registerProtobufMethod() {
    final serializer = RpcSerializer<RpcUser>(
      deserializer: RpcUser.deserialize, // Статическая функция
    );
    
    // Используем в унарном методе
    final client = UnaryClient<RpcUser, RpcUserResponse>(
      transport: transport,
      serviceName: 'UserService',
      methodName: 'getUser',
      requestSerializer: serializer,
      responseSerializer: responseSerializer,
    );
  }
}
```

## Сравнение производительности

### Текущий подход (через JSON):
```
Protobuf Object → Map<String,dynamic> → JSON String → UTF8 Bytes
```
**Шагов: 4, Накладные расходы: высокие**

### Новый подход (прямые байты):
```
Protobuf Object → Bytes
```
**Шагов: 1, Накладные расходы: минимальные**

## Миграционная стратегия

### Вариант 1: Мягкая миграция

```dart
// Адаптер для старых toJson() реализаций
abstract class JsonCompatibleMessage implements IRpcSerializableMessage {
  Map<String, dynamic> toJson(); // Старый метод
  
  @override
  Uint8List serialize() {
    // Автоматическая конверсия
    final json = jsonEncode(toJson());
    return Uint8List.fromList(utf8.encode(json));
  }
}

// Старые классы наследуются от адаптера
class OldRpcString extends JsonCompatibleMessage {
  final String value;
  
  @override
  Map<String, dynamic> toJson() => {'value': value};
}
```

### Вариант 2: Постепенная замена

1. Добавить `serialize()` как опциональный метод
2. Если `serialize()` реализован - использовать его
3. Иначе - fallback на `toJson()`
4. В будущей версии убрать `toJson()`

```dart
abstract interface class IRpcSerializableMessage {
  // Новый метод
  Uint8List? serialize() => null; // По умолчанию null
  
  // Старый метод (deprecated)
  @Deprecated('Use serialize() instead')
  Map<String, dynamic>? toJson() => null;
}
```

## Преимущества нового подхода

### 🚀 Производительность
- **Protobuf**: убираем 3 лишних конверсии
- **MessagePack**: прямая бинарная сериализация
- **Custom formats**: полная свобода в выборе формата

### 🎯 Гибкость
- Каждый тип может выбрать оптимальный формат сериализации
- Не привязаны к JSON
- Можем использовать сжатие, шифрование и т.д.

### 🧹 Простота
- Сериализатор становится простой проксей
- Меньше промежуточных слоев
- Меньше places для ошибок

### 🔧 Совместимость
- JSON реализации остаются рабочими
- Легкая миграция через адаптеры
- Protobuf получает максимальную эффективность

## Заключение

Переход на `Uint8List serialize()` даст нам:

1. **Прямую сериализацию** без JSON промежуточного слоя
2. **Максимальную производительность** для protobuf
3. **Гибкость** в выборе формата сериализации
4. **Упрощение** архитектуры сериализатора

Это особенно ценно для protobuf интеграции, где мы можем убрать 75% лишних конверсий! 