# Быстрый старт

Добро пожаловать в **RPC Dart**! Это руководство поможет вам быстро начать работу с RPC Dart в вашем проекте на Dart или Flutter.

## Установка

Добавьте RPC Dart в ваш проект, выполнив следующую команду:

### Dart

```bash
dart pub add rpc_dart
```
  
### Flutter

```bash
flutter pub add rpc_dart
```
  

Для дополнительных типов транспортов (HTTP, WebSocket, Isolate) также добавьте:

```bash
dart pub add rpc_dart_transports
```

## Ваш первый RPC сервис

Давайте создадим простой сервис калькулятора для демонстрации основных концепций RPC Dart.

### 1. Определите контракт

Сначала определите контракт сервиса с константами для имён сервиса и методов:

```dart
// calculator_contract.dart
abstract interface class ICalculatorContract {
  static const name = 'Calculator';
  static const methodAdd = 'add';
}
```

### 2. Создайте модели запросов/ответов

Определите модели данных для ваших RPC вызовов:

```dart
// models.dart
class AddRequest {
  final double a;
  final double b;
  
  AddRequest(this.a, this.b);
}

class AddResponse {
  final double result;
  
  AddResponse(this.result);
}
```

### 3. Реализуйте сервер (Responder)

Создайте responder, который обрабатывает входящие RPC вызовы:

```dart
// calculator_responder.dart

final class CalculatorResponder extends RpcResponderContract {
  CalculatorResponder() : super(ICalculatorContract.name);

  @override
  void setup() {
// Регистрируем обработчик унарного метода
addUnaryMethod<AddRequest, AddResponse>(
  methodName: ICalculatorContract.methodAdd,
  handler: _add,
);
  }

  Future<AddResponse> _add(AddRequest request, {RpcContext? context}) async {
final result = request.a + request.b;
return AddResponse(result);
  }
}
```

### 4. Создайте клиент (Caller)

Реализуйте клиент, который вызывает RPC методы:

```dart
// calculator_caller.dart

final class CalculatorCaller extends RpcCallerContract {
  CalculatorCaller(RpcCallerEndpoint endpoint) 
: super(ICalculatorContract.name, endpoint);

  Future<AddResponse> add(AddRequest request) {
return callUnary<AddRequest, AddResponse>(
  methodName: ICalculatorContract.methodAdd,
  request: request,
);
  }
}
```

### 5. Объедините всё вместе

Теперь давайте создадим полный пример, который настраивает транспорт, эндпоинты и делает RPC вызов:

```dart
// main.dart

void main() async {
  // Создаём пару InMemory транспортов
  final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();
  
  // Настраиваем responder endpoint
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(CalculatorResponder());
  responder.start();
  
  // Настраиваем caller endpoint
  final caller = RpcCallerEndpoint(transport: clientTransport);
  
  // Создаём клиент калькулятора
  final calculator = CalculatorCaller(caller);
  
  // Делаем RPC вызов
  final result = await calculator.add(AddRequest(10, 5));
  print('10 + 5 = ${result.result}'); // Вывод: 10 + 5 = 15.0
  
  // Очистка ресурсов
  await caller.close();
  await responder.close();
}
```

## Ключевые преимущества

🚀 **Производительность без копирования**: С InMemory транспортом объекты передаются напрямую без накладных расходов на сериализацию.

🔒 **Типобезопасность**: Все RPC вызовы строго типизированы, ошибки обнаруживаются на этапе компиляции.

🧪 **Лёгкое тестирование**: InMemory транспорт делает модульное и интеграционное тестирование простым.

🔌 **Независимость от транспорта**: Переключайтесь между InMemory, HTTP, WebSocket без изменения бизнес-логики.

## Следующие шаги

- Изучите [Основные концепции](core-concepts.md) для понимания архитектуры RPC Dart
- Изучите различные [типы транспортов](transports/inmemory.md) для разных случаев использования
- Ознакомьтесь с [паттернами стриминга](../guides/streaming-patterns.md) для потоковой и двунаправленной коммуникации
- Изучите [маршрутизацию и композицию](../guides/routing-and-composition.md) для структурирования больших приложений

## Нужна помощь?

- Изучите [гид по обработке ошибок](../guides/error-handling.md), чтобы быстрее находить ответы на типовые вопросы
- Просмотрите [примеры на GitHub](https://github.com/nogipx/rpc_dart/tree/main/example)
- Создайте issue на [GitHub](https://github.com/nogipx/rpc_dart/issues), если нашли баги или у вас есть вопросы
