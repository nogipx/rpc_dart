# Документация двунаправленного стрима в gRPC

Данный документ содержит подробное описание компонентов и принципов работы 
двунаправленного (Bidirectional) стриминга в gRPC, согласно спецификации.

## 1. Что такое двунаправленный стрим?

Двунаправленный стрим (Bidirectional Streaming) - это режим взаимодействия в gRPC,
при котором клиент и сервер могут отправлять друг другу последовательности сообщений
независимо и асинхронно. В отличие от унарного вызова (один запрос - один ответ),
серверного или клиентского стриминга, двунаправленный стрим позволяет:

- Клиенту отправлять множество сообщений, не дожидаясь ответа сервера
- Серверу отправлять множество сообщений, не дожидаясь всех запросов клиента
- Обоим участникам обмениваться сообщениями в произвольном порядке и времени
- Сохранять порядок сообщений в каждом направлении

Эта модель построена на базе единого HTTP/2 потока (stream), где каждая сторона
может отправлять сообщения в своём направлении независимо от другой.

## 2. Ключевые компоненты реализации

### 2.1. Транспортный уровень (Http2Transport)

`Http2Transport` - абстрактный класс, представляющий соединение HTTP/2.
Он отвечает за:

- Создание и управление HTTP/2 соединением
- Отправку заголовков (HEADERS фреймы) и данных (DATA фреймы)
- Предоставление API для работы с потоками сообщений
- Управление жизненным циклом соединения

### 2.2. Фрейминг сообщений (GrpcMessageFrame)

Класс `GrpcMessageFrame` отвечает за упаковку и распаковку сообщений в формате gRPC.
Каждое сообщение обрамляется 5-байтным префиксом, который содержит:

- 1 байт - флаг сжатия (0 = не сжато, 1 = сжато)
- 4 байта - длина сообщения в байтах (big-endian uint32)

Этот формат стандартизирован протоколом gRPC и должен строго соблюдаться
для совместимости с другими реализациями.

### 2.3. Кодеки сообщений (MessageCodec)

Интерфейс `MessageCodec<T>` определяет способ сериализации и десериализации
сообщений в байтовую последовательность и обратно. Реализации могут использовать
различные форматы данных, например:

- JSON
- Protocol Buffers
- MessagePack
- Пользовательские бинарные форматы

### 2.4. Клиент (BidirectionalStreamClient)

`BidirectionalStreamClient` - класс, реализующий двунаправленный стрим
на стороне клиента. Он позволяет:

- Отправлять запросы в сервер через метод `send`
- Получать ответы через поток `responses`
- Завершать поток запросов методом `finishSending`
- Полностью закрывать стрим методом `close`

### 2.5. Сервер (BidirectionalStreamServer)

`BidirectionalStreamServer` - серверная часть двунаправленного стрима.
Он отвечает за:

- Получение потока запросов от клиента через `requests`  
- Отправку ответов через метод `send`
- Отправку статусов и ошибок через метод `sendError`
- Завершение потока ответов методом `finishSending`

### 2.6. Обработка метаданных (Metadata)

Класс `Metadata` представляет HTTP/2 заголовки и трейлеры, используемые для:

- Установки пути метода (`:path = /{ServiceName}/{MethodName}`)
- Передачи служебной информации (content-type, grpc-encoding и т.д.)
- Передачи статусов завершения (`grpc-status`, `grpc-message`)
- Передачи пользовательских метаданных

### 2.7. Парсинг сообщений (GrpcMessageParser)

`GrpcMessageParser` - вспомогательный класс для обработки потока данных.
Он отвечает за:

- Буферизацию входящих данных
- Извлечение префикса и определение длины сообщения
- Сборку полных сообщений из фрагментированных данных
- Управление состоянием парсинга

## 3. Последовательность взаимодействия клиента и сервера

### 3.1. Инициализация соединения

1. **Клиент** создает HTTP/2 соединение с сервером
2. **Клиент** открывает новый HTTP/2 стрим и отправляет HEADERS с:
   - `:method = POST`
   - `:path = /{ServiceName}/{MethodName}`
   - `:scheme = http/https`
   - `:authority = host:port`
   - `content-type = application/grpc`
   - `te = trailers`
3. **Сервер** принимает заголовки, идентифицирует сервис и метод
4. **Сервер** отвечает своими HEADERS:
   - `:status = 200`
   - `content-type = application/grpc`

### 3.2. Обмен сообщениями

После инициализации начинается асинхронный обмен сообщениями:

1. **Клиент** может начать отправлять запросы через транспорт:
   - Сериализует сообщение через кодек
   - Добавляет 5-байтный префикс (1 байт сжатия + 4 байта длины)
   - Отправляет DATA фрейм с сообщением
   - Повторяет для каждого сообщения

2. **Сервер** параллельно начинает читать запросы:
   - Принимает DATA фреймы от клиента
   - Буферизует данные
   - Извлекает 5-байтный префикс
   - Собирает полные сообщения из буфера
   - Десериализует сообщения через кодек
   - Обрабатывает каждое сообщение

3. **Сервер** может одновременно отправлять ответы:
   - Сериализует ответное сообщение
   - Добавляет 5-байтный префикс
   - Отправляет DATA фрейм
   - Повторяет для каждого ответа

4. **Клиент** параллельно читает ответы:
   - Принимает DATA фреймы от сервера
   - Буферизует и собирает полные сообщения
   - Десериализует их
   - Обрабатывает каждый ответ

### 3.3. Завершение потока

Завершение может инициировать любая сторона:

1. **Клиент** завершает отправку:
   - Вызывает `finishSending()`
   - Закрывает поток отправки, устанавливая END_STREAM на последний фрейм
   - Продолжает принимать ответы от сервера

2. **Сервер** завершает отправку:
   - Вызывает `finishSending()`
   - Отправляет HEADERS (трейлеры) с полями:
     - `grpc-status = 0` (успех) или другой код (ошибка)
     - `grpc-message` (опционально, при ошибке)
   - Устанавливает END_STREAM на трейлерах

3. **Клиент** получает трейлеры и завершает свою часть потока

### 3.4. Обработка ошибок

В случае ошибок работает следующий механизм:

1. **Сервер** обнаруживает ошибку:
   - Закрывает свой поток отправки
   - Отправляет трейлеры с ненулевым кодом `grpc-status` и описанием ошибки
   - Может завершить HTTP/2 поток с RST_STREAM при критических ошибках

2. **Клиент** обнаруживает ошибку:
   - Может закрыть свою часть потока, если не хочет продолжать отправку
   - Обрабатывает ошибку на уровне приложения

## 4. Сценарии использования двунаправленного стрима

### 4.1. Чаты и мессенджеры

Идеально подходит для систем обмена сообщениями, где каждый участник может
отправлять сообщения в любое время, а другие участники получают их асинхронно.

### 4.2. Потоковая телеметрия и мониторинг

Системы, где клиент отправляет потоки данных телеметрии, а сервер может
асинхронно отправлять команды управления или конфигурации.

### 4.3. Игровые сервисы

Многопользовательские игры, где клиенты и серверы обмениваются событиями
и состояниями в реальном времени.

### 4.4. Распределенные системы

Микросервисы, которым требуется долгоживущее соединение с возможностью
двустороннего обмена событиями и командами.

### 4.5. IoT и устройства

Интернет вещей, где устройства отправляют данные, а сервер может
отправлять команды управления.

## 5. Пример использования

### Клиентская сторона:

```dart
// Создаем и инициализируем стрим
final client = await BidirectionalStreamClient.create(
  'example.com',
  50051,
  'ChatService',
  'Connect',
  JsonMessageCodec<ChatRequest>(), // Реализация кодека
  JsonMessageCodec<ChatResponse>(),
);

// Подписываемся на ответы
client.responses.listen(
  (response) {
    if (!response.isMetadataOnly) {
      print('Получено сообщение: ${response.payload}');
    }
  },
  onError: (error) => print('Ошибка: $error'),
  onDone: () => print('Стрим ответов завершен'),
);

// Отправляем сообщения
client.send(ChatRequest(message: 'Привет!'));
client.send(ChatRequest(message: 'Как дела?'));

// Позже завершаем отправку, но продолжаем получать ответы
client.finishSending();

// В конце закрываем всё соединение
client.close();
```

### Серверная сторона:

```dart
class ChatHandler implements BidirectionalStreamHandlerFactory<ChatRequest, ChatResponse> {
  @override
  Stream<ChatResponse> handle(Stream<ChatRequest> requests) async* {
    // Обрабатываем входящий поток запросов
    await for (final request in requests) {
      print('Получен запрос: ${request.message}');
      
      // Отправляем ответ
      yield ChatResponse(message: 'Вы написали: ${request.message}');
    }
    
    // После завершения потока запросов можем отправить финальный ответ
    yield ChatResponse(message: 'Соединение закрыто');
  }
}

// Регистрация обработчика в сервере
grpcServer.registerService(
  'ChatService',
  'Connect',
  ChatHandler(),
  JsonMessageCodec<ChatRequest>(),
  JsonMessageCodec<ChatResponse>()
);
```

## 6. Технические детали и оптимизации

### 6.1. Управление потоком (Flow Control)

HTTP/2 имеет встроенный механизм управления потоком на основе окна кредитов.
Каждый получатель указывает, сколько данных он готов принять:

- Начальный размер окна по умолчанию: 65535 байт
- Получатель отправляет WINDOW_UPDATE для увеличения окна
- Если окно исчерпано, отправитель блокируется до получения WINDOW_UPDATE

Реализация `Http2Transport` должна учитывать управление потоком,
чтобы избежать блокировок и переполнения буферов.

### 6.2. Буферизация и фрагментация

Сообщения gRPC могут быть разделены на несколько HTTP/2 DATA фреймов,
а границы DATA фреймов не обязательно совпадают с границами сообщений.
Наша реализация `GrpcMessageParser` корректно обрабатывает:

- Сборку фрагментированных сообщений
- Обработку нескольких сообщений в одном DATA фрейме
- Обработку сообщений, разделенных между несколькими DATA фреймами

### 6.3. Отмена и таймауты

gRPC поддерживает отмену операций и таймауты:

- Клиент может передавать `deadline` в заголовке `grpc-timeout`
- Серверу следует прервать операцию при превышении deadline
- Любая сторона может прервать поток, отправив ошибку (например, CANCELLED)

### 6.4. Метаданные и трейлеры

Клиент и сервер могут обмениваться метаданными:

- Начальные метаданные отправляются в HTTP/2 HEADERS
- Конечные метаданные (от сервера) отправляются в HTTP/2 TRAILERS
- Статус завершения всегда передается в трейлерах как `grpc-status`

## 7. Особенности реализации

### 7.1. Многопоточность и блокировки

При реализации двунаправленного стрима важно учитывать:

- Чтение и запись могут происходить параллельно
- Доступ к разделяемым ресурсам должен быть синхронизирован
- Следует избегать блокирующих операций в потоках обработки

### 7.2. Безопасность

Для безопасного обмена данными:

- Рекомендуется использовать TLS (HTTPS)
- Проверять сертификаты и валидировать соединения
- Реализовать механизмы аутентификации и авторизации

### 7.3. Совместимость с другими реализациями

Для обеспечения совместимости с другими клиентами/серверами gRPC:

- Строго следовать протоколу HTTP/2
- Соблюдать формат 5-байтного префикса сообщений
- Правильно обрабатывать заголовки и трейлеры
- Корректно передавать коды статусов в трейлерах 