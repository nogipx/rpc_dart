# Основные концепции

RPC Dart построен на нескольких основных концепциях, которые работают вместе для предоставления мощного и гибкого фреймворка удалённых вызовов процедур. Понимание этих концепций необходимо для эффективного использования библиотеки.

## Ключевые компоненты

- **Контракты** – Определяют интерфейс между сервисами с именами методов и их сигнатурами.
  
- **Эндпоинты** – Обрабатывают коммуникацию между клиентской и серверной сторонами.
  
- **Транспорты** – Управляют базовым механизмом коммуникации (InMemory, HTTP, WebSocket и т.д.).
  
- **Контекст** – Переносят метаданные и управляющую информацию через RPC вызовы.
  

## Контракты

Контракты в RPC Dart определяют интерфейс сервиса - какие методы доступны и как их следует вызывать. Они служат **единым источником истины** для реализаций как клиента, так и сервера.

### Определение контракта

```dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
  static const methodSubtract = 'subtract';
  static const methodDivide = 'divide';
}
```

### Преимущества

- **Типобезопасность**: Обеспечивает согласованность сигнатур методов между клиентом и сервером
- **Документация**: Служит живой документацией доступных сервисов
- **Версионность**: Легко версионировать и развивать ваш API
- **Генерация кода**: Может использоваться для генерации клиентских и серверных заглушек

## Эндпоинты

Эндпоинты - это точки коммуникации, которые обрабатывают RPC вызовы. Существует два типа:

### RpcCallerEndpoint (Клиент)

Клиентский эндпоинт, который инициирует RPC вызовы:

```dart
final caller = RpcCallerEndpoint(transport: transport);
final calculator = CalculatorCaller(caller);

// Делаем RPC вызов
final result = await calculator.add(AddRequest(5, 3));
```

### RpcResponderEndpoint (Сервер)

Серверный эндпоинт, который обрабатывает входящие RPC вызовы:

```dart
final responder = RpcResponderEndpoint(transport: transport);
responder.registerServiceContract(CalculatorResponder());
responder.start();
```

## Транспорты

Транспорты определяют **как** сообщения отправляются между эндпоинтами. RPC Dart независим от транспорта, что означает, что вы можете переключать транспорты без изменения бизнес-логики.

### Доступные транспорты

| Транспорт | Случай использования | Производительность | Сложность |
|-----------|---------------------|-------------------|-----------|
| **InMemory** | Тестирование, одиночный процесс | Высшая (без копирования) | Низшая |
| **HTTP** | Веб-сервисы, микросервисы | Средняя | Средняя |
| **WebSocket** | Реальное время, двунаправленная | Средняя | Средняя |
| **Isolate** | Многоядерность, изоляция | Высокая | Высшая |

### Пример транспорта

```dart

// Разработка/Тестирование
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

// Продакшн HTTP/2 (внутри async-функции)
final httpTransport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
);

// Реальное время WebSocket
final wsTransport = RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);
```

Один и тот же код сервиса работает с любым транспортом!

## Контекст

RPC Контекст переносит дополнительную информацию вместе с фактическими данными RPC вызова:

### Что содержит контекст

- **Correlation ID**: Уникальный идентификатор для трассировки запросов
- **Deadline**: Информация о таймауте запроса
- **Metadata**: Пользовательские пары ключ-значение
- **Cancellation**: Возможность отменять текущие операции

### Использование контекста

```dart
// Серверная сторона - доступ к контексту
Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
  final correlationId = context?.correlationId;
  final userAgent = context?.getHeader('user-agent');

  if (context?.isCancelled ?? false) {
throw RpcException('Запрос был отменён');
  }

  return AddResponse(request.a + request.b);
}

// Клиентская сторона - передача метаданных
final context = RpcContextBuilder()
.withHeader('user-agent', 'MyApp/1.0')
.withTimeout(const Duration(seconds: 5))
.build();

final result = await calculator.add(
  AddRequest(5, 3),
  context: context,
);
```

## Типы RPC

RPC Dart поддерживает все стандартные паттерны RPC коммуникации:

### Унарный RPC

Простой паттерн запрос-ответ:

```dart
Future<AddResponse> add(AddRequest request) {
  return callUnary<AddRequest, AddResponse>(
methodName: 'add',
request: request,
  );
}
```

### Серверная потоковая передача

Сервер отправляет несколько ответов на один запрос:

```dart
Stream<NumberResponse> getNumbers(NumberRequest request) {
  return callServerStream<NumberRequest, NumberResponse>(
methodName: 'getNumbers',
request: request,
  );
}
```

### Клиентская потоковая передача

Клиент отправляет несколько запросов, сервер отвечает один раз:

```dart
Future<SumResponse> sumNumbers(Stream<NumberRequest> requests) {
  return callClientStream<NumberRequest, SumResponse>(
methodName: 'sumNumbers',
requests: requests,
  );
}
```

### Двунаправленная потоковая передача

И клиент, и сервер могут отправлять несколько сообщений:

```dart
Stream<EchoResponse> echo(Stream<EchoRequest> requests) {
  return callBidirectionalStream<EchoRequest, EchoResponse>(
methodName: 'echo',
requests: requests,
  );
}
```

## Оптимизация без копирования

Одна из уникальных особенностей RPC Dart - передача объектов **без копирования** с InMemory транспортом:

```dart
class LargeData {
  final List<int> data = List.generate(1000000, (i) => i);
}

// С InMemory транспортом этот объект передаётся по ссылке
// Без накладных расходов на сериализацию!
final result = await service.processLargeData(LargeData());
```

### Преимущества

- **Максимальная производительность**: Без накладных расходов на сериализацию
- **Эффективность памяти**: Объекты не дублируются
- **Сохранение типов**: Полная информация о типах Dart сохраняется

### Когда использовать

- Одно-процессные приложения
- Высокопроизводительные вычисления
- Передача больших данных
- Разработка и тестирование

## Обработка ошибок

RPC Dart предоставляет структурированную обработку ошибок:

### RpcException

```dart
// Сервер выбрасывает структурированные ошибки
if (request.b == 0) {
  throw RpcException(
code: 'DIVISION_BY_ZERO',
message: 'Нельзя делить на ноль',
details: {'operand': 'b', 'value': 0},
  );
}

// Клиент перехватывает и обрабатывает
try {
  final result = await calculator.divide(DivideRequest(10, 0));
} on RpcException catch (e) {
  print('RPC Ошибка: ${e.code} - ${e.message}');
  print('Детали: ${e.details}');
}
```

## Поддержка middleware

RPC Dart поддерживает middleware для сквозных задач:

```dart
// Middleware логирования
class LoggingMiddleware implements IRpcMiddleware {
  @override
  Future<dynamic> processRequest(
String serviceName,
String methodName,
dynamic request,
  ) async {
print('Вызов $serviceName.$methodName');
return request;
  }

  @override
  Future<dynamic> processResponse(
String serviceName,
String methodName,
dynamic response,
  ) async {
print('Завершён $serviceName.$methodName');
return response;
  }
}

// Регистрация middleware (для запуска хуков расширьте эндпоинт)
responder.addMiddleware(LoggingMiddleware());
```

> **Примечание.** Базовые эндпоинты хранят зарегистрированные middleware и
> отображают их количество в диагностике. Чтобы запускать хуки до/после
> обработчиков уже сейчас, расширьте эндпоинт и вызовите
> `processRequest`/`processResponse` вручную.

## Лучшие практики

### Дизайн сервисов

1. **Держите контракты простыми**: Одна ответственность на сервис
2. **Используйте значимые имена**: Понятные имена методов и параметров
3. **Версионируйте контракты**: Планируйте эволюцию API
4. **Обрабатывайте ошибки изящно**: Используйте структурированные ответы об ошибках

### Производительность

1. **Выбирайте подходящий транспорт**: InMemory для одного процесса, HTTP для распределённых систем
2. **Используйте потоки**: Для больших наборов данных или коммуникации в реальном времени
3. **Реализуйте таймауты**: Устанавливайте разумные дедлайны для запросов
4. **Рассмотрите пакетирование**: Группируйте связанные операции

### Тестирование

1. **Используйте InMemory транспорт**: Для быстрых, изолированных тестов
2. **Создавайте моки сервисов**: Создавайте тестовые реализации контрактов
3. **Тестируйте сценарии ошибок**: Проверяйте, что обработка ошибок работает корректно
4. **Интеграционное тестирование**: Тестируйте с реальными транспортами

## Следующие шаги

Теперь, когда вы понимаете основные концепции, изучите:

- [Архитектура](architecture.md) - Изучите паттерны архитектуры CORD
- [Типы транспортов](transports/inmemory.md) - Глубокое погружение в доступные транспорты
- [Паттерны стриминга](../guides/streaming-patterns.md) - Подробные примеры каждого паттерна RPC
- [Тестирование и инструменты](../guides/testing-and-debugging.md) - Лучшие практики тестирования RPC приложений
