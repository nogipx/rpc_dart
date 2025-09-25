# Пользовательский транспорт

Функция **Пользовательского транспорта** позволяет создавать собственные реализации транспортов для интеграции RPC Dart с любыми протоколами связи, системами обмена сообщениями или фреймворками. Это дает полную гибкость для адаптации RPC Dart под ваши специфические требования инфраструктуры.

## Обзор

- **Гибкость протоколов** – Реализуйте любой протокол связи - от очередей сообщений до пользовательских сетевых протоколов и экзотических транспортных механизмов.
  
- **Интеграция с инфраструктурой** – Легко интегрируйтесь с существующей инфраструктурой как Redis, RabbitMQ, Apache Kafka или проприетарными системами.
  
- **Оптимизация производительности** – Оптимизируйте под ваш конкретный случай использования с пользовательской сериализацией, сжатием и стратегиями управления соединениями.
  
- **Полный контроль** – Полный контроль над маршрутизацией сообщений, обработкой ошибок, безопасностью и характеристиками производительности.
  

## Инструментарий разработки транспортов

RPC Dart предоставляет богатый набор утилит и базовых классов для упрощения создания пользовательских транспортов. Этот инструментарий включает готовые решения для управления соединениями, сериализации сообщений, буферизации и других общих задач транспортного уровня.

### Базовые классы транспортов

- **RpcBaseTransport** – Абстрактный базовый класс, который предоставляет стандартную реализацию управления жизненным циклом транспорта:

```dart

class MyCustomTransport extends RpcBaseTransport {
  @override
  bool get supportsZeroCopy => false;

  @override
  Future<void> doConnect() async {
// Ваша логика подключения
  }

  @override
  Future<void> doSendMetadata(int streamId, RpcMetadata metadata, {bool endStream = false}) async {
// Ваша логика отправки метаданных
  }

  @override
  Future<void> doSendMessage(int streamId, Uint8List data, {bool endStream = false}) async {
// Ваша логика отправки сообщений
  }

  @override
  Future<void> doFinishSending(int streamId) async {
// Ваша логика завершения отправки
  }

  @override
  Future<void> doClose() async {
// Ваша логика закрытия соединения
  }
}
```

### Утилиты транспорта

- **RpcTransportUtils** – Набор статических утилит для работы с транспортными сообщениями:

```dart
// Создание сообщений
final message = RpcTransportUtils.createMessage(
  streamId: 123,
  payload: data,
  metadata: metadata,
);

// Работа с метаданными
final authMetadata = RpcTransportUtils.createMetadata([
  RpcHeader('authorization', 'Bearer token123'),
  RpcHeader('content-type', 'application/protobuf'),
]);

// Фрейминг сообщений для потоковых протоколов
final framedData = RpcTransportUtils.frameMessage(data);
final unframedData = RpcTransportUtils.unframeMessage(framedData);

// Валидация
if (RpcTransportUtils.isValidStreamId(streamId, isClient: true)) {
  // Отправка сообщения
}
```

### Миксины для расширения функциональности

- **RpcZeroCopySupport** – Добавляет поддержку zero-copy операций:

```dart
class MyInMemoryTransport extends RpcBaseTransport with RpcZeroCopySupport {
  @override
  bool get supportsZeroCopy => true;

  @override
  Future<void> doSendDirectObject(int streamId, Object object, {bool endStream = false}) async {
// Прямая передача объекта без сериализации
incomingController.add(RpcTransportMessage.withDirectObject(
  streamId: streamId,
  directPayload: object,
  isEndOfStream: endStream,
));
  }
}
```

- **RpcMessageBuffering** – Добавляет буферизацию сообщений для оптимизации производительности:

```dart
class MyBufferedTransport extends RpcBaseTransport with RpcMessageBuffering {
  MyBufferedTransport() {
configureBuffering(
  maxBufferSize: 1024 * 1024, // 1MB
  flushInterval: Duration(milliseconds: 100),
  enableBatching: true,
);
  }

  @override
  Future<void> doSendBufferedMessages(List<BufferedMessage> messages) async {
// Отправка пакета сообщений за один раз
for (final message in messages) {
  await _actualSend(message.streamId, message.data);
}
  }
}
```

- **RpcAutoReconnect** – Добавляет автоматическое переподключение:

```dart
class MyReliableTransport extends RpcBaseTransport with RpcAutoReconnect {
  MyReliableTransport() {
configureReconnection(
  maxAttempts: 5,
  initialDelay: Duration(seconds: 1),
  maxDelay: Duration(seconds: 30),
  backoffMultiplier: 2.0,
);
  }

  @override
  Future<bool> checkConnection() async {
// Проверка состояния соединения
return _socket?.isConnected ?? false;
  }

  @override
  Future<void> attemptReconnection() async {
// Логика переподключения
await doConnect();
  }
}
```

### Сериализация сообщений

- **RpcMessageSerialization** – Утилиты для сериализации транспортных сообщений в различные форматы:

```dart
// Сериализация в JSON (для текстовых протоколов)
final jsonData = RpcMessageSerialization.toJson(message);
final restoredMessage = RpcMessageSerialization.fromJson(jsonData);

// Сериализация в бинарный формат (для производительности)
final binaryData = RpcMessageSerialization.toBinary(message);
final restoredMessage = RpcMessageSerialization.fromBinary(binaryData);
```

- **RpcMetadataConverter** – Конвертер метаданных для различных протоколов:

```dart
// Конвертация в HTTP headers
final httpHeaders = RpcMetadataConverter.toStringMap(metadata);

// Создание из gRPC metadata
final grpcMetadata = RpcMetadataConverter.fromPairList(grpcHeaders);

// Фильтрация по префиксу
final authHeaders = RpcMetadataConverter.filterByPrefix(metadata, 'auth-');

// Добавление префикса для избежания конфликтов
final prefixedMetadata = RpcMetadataConverter.addPrefix(metadata, 'rpc-');
```

### Конфигурация транспортов

- **RpcTransportConfigBuilder** – Fluent API для создания конфигураций транспортов:

```dart
final config = RpcTransportConfigBuilder()
  .role(isClient: true)
  .buffering(
maxBufferSize: 1024 * 1024,
flushInterval: Duration(milliseconds: 50),
enableBatching: true,
  )
  .reconnection(
enabled: true,
maxAttempts: 3,
initialDelay: Duration(seconds: 1),
backoffMultiplier: 1.5,
  )
  .timeouts(
connectionTimeout: Duration(seconds: 30),
requestTimeout: Duration(seconds: 60),
  )
  .performance(
enableZeroCopy: true,
enableCompression: false,
maxConcurrentStreams: 100,
  )
  .custom('encryption', {'algorithm': 'AES256', 'keySize': 256})
  .build();

// Использование конфигурации
if (config.has('buffering')) {
  final bufferConfig = config['buffering'] as Map<String, dynamic>;
  // Настройка буферизации
}
```

## Интерфейс транспорта

### Базовый контракт транспорта

Все пользовательские транспорты должны реализовывать интерфейс `IRpcTransport`:

```dart
abstract class IRpcTransport {
  /// Возвращает true, если это клиентский транспорт
  bool get isClient;
  
  /// Возвращает true, если транспорт закрыт
  bool get isClosed;
  
  /// Возвращает true, если транспорт поддерживает zero-copy операции
  bool get supportsZeroCopy => false;
  
  /// Создает новый HTTP/2 stream для RPC вызова
  int createStream();
  
  /// Освобождает ID стрима
  bool releaseStreamId(int streamId);
  
  /// Отправляет метаданные для конкретного stream
  Future<void> sendMetadata(int streamId, RpcMetadata metadata, {bool endStream = false});
  
  /// Отправляет сообщение для конкретного stream
  Future<void> sendMessage(int streamId, Uint8List data, {bool endStream = false});
  
  /// Отправляет объект напрямую без сериализации (zero-copy)
  Future<void> sendDirectObject(int streamId, Object object, {bool endStream = false});
  
  /// Поток всех входящих сообщений от удаленной стороны
  Stream<RpcTransportMessage> get incomingMessages;
  
  /// Создает отфильтрованный поток сообщений для конкретного stream
  Stream<RpcTransportMessage> getMessagesForStream(int streamId);
  
  /// Завершает отправку данных для конкретного stream
  Future<void> finishSending(int streamId);
  
  /// Закрывает транспортное соединение
  Future<void> close();
}
```

### Структура сообщения

RPC сообщения следуют стандартизированной структуре:

```dart
final class RpcTransportMessage {
  /// Полезная нагрузка сообщения (сериализованные данные)
  final Uint8List? payload;

  /// ZERO-COPY: Прямая ссылка на объект (для inmemory транспорта)
  final Object? directPayload;

  /// Связанные метаданные
  final RpcMetadata? metadata;

  /// Флаг, указывающий, что это последнее сообщение в потоке
  final bool isEndOfStream;

  /// Путь метода в формате /ServiceName/MethodName
  final String? methodPath;

  /// Уникальный идентификатор HTTP/2 stream для этого RPC вызова
  final int streamId;

  /// Флаг, указывающий, что сообщение содержит только метаданные
  bool get isMetadataOnly => metadata != null && payload == null && directPayload == null;

  /// Флаг, указывающий что передается объект напрямую (ZERO-COPY оптимизация)
  bool get isDirect => directPayload != null;

  /// Флаг, указывающий что передаются сериализованные байты
  bool get isSerialized => payload != null;
}
```

## Примеры реализации

### 1. Redis транспорт

Транспорт использующий Redis pub/sub для связи:

### Redis транспорт

```dart
// redis_transport.dart

class RpcRedisTransport implements RpcTransport {
  final RedisConnection _redis;
  final String _requestChannel;
  final String _responseChannel;
  final StreamController<RpcMessage> _messageController = StreamController.broadcast();
  
  late Command _publisher;
  late PubSub _subscriber;
  bool _isConnected = false;
  
  RpcRedisTransport({
    required RedisConnection redis,
    required String requestChannel,
    required String responseChannel,
  }) : _redis = redis,
       _requestChannel = requestChannel,
       _responseChannel = responseChannel;
  
  @override
  Stream<RpcMessage> get messageStream => _messageController.stream;
  
  @override
  bool get isConnected => _isConnected;
  
  @override
  Map<String, dynamic> get configuration => {
    'transport_type': 'redis',
    'request_channel': _requestChannel,
    'response_channel': _responseChannel,
  };
  
  @override
  Future<void> connect() async {
    if (_isConnected) return;
    
    try {
      // Настройка издателя для отправки сообщений
      _publisher = await _redis.connect();
      
      // Настройка подписчика для получения сообщений
      _subscriber = await _redis.subscribe();
      await _subscriber.subscribe([_responseChannel]);
      
      // Прослушивание входящих сообщений
      _subscriber.getStream().listen((message) {
        if (message.isNotEmpty) {
          _handleIncomingMessage(message.last);
        }
      });
      
      _isConnected = true;
      print('Redis транспорт подключен');
      
    } catch (e) {
      print('Не удалось подключить Redis транспорт: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> sendMessage(RpcMessage message) async {
    if (!_isConnected) {
      throw StateError('Транспорт не подключен');
    }
    
    try {
      final serialized = _serializeMessage(message);
      await _publisher.send_object([
        'PUBLISH',
        _requestChannel,
        serialized,
      ]);
      
    } catch (e) {
      print('Не удалось отправить сообщение: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> close() async {
    if (!_isConnected) return;
    
    try {
      await _subscriber.unsubscribe([_responseChannel]);
      await _publisher.get_connection().close();
      await _messageController.close();
      _isConnected = false;
      
    } catch (e) {
      print('Ошибка закрытия Redis транспорта: $e');
    }
  }
  
  void _handleIncomingMessage(String rawMessage) {
    try {
      final message = _deserializeMessage(rawMessage);
      _messageController.add(message);
      
    } catch (e) {
      print('Не удалось обработать входящее сообщение: $e');
    }
  }
  
  String _serializeMessage(RpcMessage message) {
    return jsonEncode({
      'id': message.id,
      'contract_name': message.contractName,
      'method_name': message.methodName,
      'type': message.type.toString(),
      'headers': message.headers,
      'payload': message.payload,
      'context': message.context?.toJson(),
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  RpcMessage _deserializeMessage(String rawMessage) {
    final data = jsonDecode(rawMessage) as Map<String, dynamic>;
    
    return RpcMessage(
      id: data['id'] as String,
      contractName: data['contract_name'] as String,
      methodName: data['method_name'] as String,
      type: RpcMessageType.values.firstWhere(
        (t) => t.toString() == data['type'],
      ),
      headers: Map<String, String>.from(data['headers'] ?? {}),
      payload: data['payload'],
      context: data['context'] != null 
        ? RpcContext.fromJson(data['context'])
        : null,
    );
  }
}
```
  
  
### Пример использования

```dart
// redis_transport_example.dart
void main() async {
  // Настройка Redis соединения
  final redis = RedisConnection();
  
  // Создание транспорта для клиента
  final clientTransport = RpcRedisTransport(
    redis: redis,
    requestChannel: 'rpc_requests',
    responseChannel: 'rpc_responses_client',
  );
  
  // Создание транспорта для сервера
  final serverTransport = RpcRedisTransport(
    redis: redis,
    requestChannel: 'rpc_requests',
    responseChannel: 'rpc_responses_server',
  );
  
  // Настройка сервера
  final responder = RpcResponderEndpoint(transport: serverTransport);
  responder.registerServiceContract(CalculatorResponder());
  await responder.start();
  
  // Настройка клиента
  final caller = RpcCallerEndpoint(transport: clientTransport);
  final calculator = CalculatorCaller(caller);
  
  try {
    // Выполнение RPC вызова через Redis
    final result = await calculator.add(AddRequest(a: 10, b: 5));
    print('Результат: ${result.sum}');
    
  } finally {
    await caller.close();
    await responder.close();
  }
}
```
  

### 2. Транспорт очереди сообщений

Транспорт использующий RabbitMQ для надежной доставки сообщений:

### RabbitMQ транспорт

```dart
// rabbitmq_transport.dart

class RpcRabbitMQTransport implements RpcTransport {
  final String _connectionString;
  final String _requestQueue;
  final String _responseQueue;
  final RabbitMQTransportOptions _options;
  
  late Client _client;
  late Channel _channel;
  late Queue _requestQueueHandler;
  late Queue _responseQueueHandler;
  
  final StreamController<RpcMessage> _messageController = StreamController.broadcast();
  bool _isConnected = false;
  
  RpcRabbitMQTransport({
    required String connectionString,
    required String requestQueue,
    required String responseQueue,
    RabbitMQTransportOptions? options,
  }) : _connectionString = connectionString,
       _requestQueue = requestQueue,
       _responseQueue = responseQueue,
       _options = options ?? RabbitMQTransportOptions();
  
  @override
  Stream<RpcMessage> get messageStream => _messageController.stream;
  
  @override
  bool get isConnected => _isConnected;
  
  @override
  Map<String, dynamic> get configuration => {
    'transport_type': 'rabbitmq',
    'request_queue': _requestQueue,
    'response_queue': _responseQueue,
    'durable': _options.durable,
    'auto_delete': _options.autoDelete,
  };
  
  @override
  Future<void> connect() async {
    if (_isConnected) return;
    
    try {
      // Подключение к RabbitMQ
      _client = Client(settings: ConnectionSettings.fromUri(_connectionString));
      _channel = await _client.channel();
      
      // Объявление очередей
      _requestQueueHandler = await _channel.queue(
        _requestQueue,
        durable: _options.durable,
        autoDelete: _options.autoDelete,
      );
      
      _responseQueueHandler = await _channel.queue(
        _responseQueue,
        durable: _options.durable,
        autoDelete: _options.autoDelete,
      );
      
      // Настройка потребителя для ответов
      final consumer = await _responseQueueHandler.consume();
      consumer.listen((AmqpMessage message) {
        _handleIncomingMessage(String.fromCharCodes(message.payload!));
        message.ack();
      });
      
      _isConnected = true;
      print('RabbitMQ транспорт подключен');
      
    } catch (e) {
      print('Не удалось подключить RabbitMQ транспорт: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> sendMessage(RpcMessage message) async {
    if (!_isConnected) {
      throw StateError('Транспорт не подключен');
    }
    
    try {
      final serialized = _serializeMessage(message);
      final messageProperties = MessageProperties();
      
      // Установка свойств сообщения для надежности
      messageProperties.deliveryMode = _options.persistent ? 2 : 1;
      messageProperties.timestamp = DateTime.now();
      messageProperties.messageId = message.id;
      messageProperties.correlationId = message.context?.correlationId;
      
      await _requestQueueHandler.publish(
        serialized,
        properties: messageProperties,
      );
      
    } catch (e) {
      print('Не удалось отправить сообщение: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> close() async {
    if (!_isConnected) return;
    
    try {
      await _channel.close();
      await _client.close();
      await _messageController.close();
      _isConnected = false;
      
    } catch (e) {
      print('Ошибка закрытия RabbitMQ транспорта: $e');
    }
  }
  
  void _handleIncomingMessage(String rawMessage) {
    try {
      final message = _deserializeMessage(rawMessage);
      _messageController.add(message);
      
    } catch (e) {
      print('Не удалось обработать входящее сообщение: $e');
    }
  }
  
  String _serializeMessage(RpcMessage message) {
    return jsonEncode({
      'id': message.id,
      'contract_name': message.contractName,
      'method_name': message.methodName,
      'type': message.type.toString(),
      'headers': message.headers,
      'payload': message.payload,
      'context': message.context?.toJson(),
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  RpcMessage _deserializeMessage(String rawMessage) {
    final data = jsonDecode(rawMessage) as Map<String, dynamic>;
    
    return RpcMessage(
      id: data['id'] as String,
      contractName: data['contract_name'] as String,
      methodName: data['method_name'] as String,
      type: RpcMessageType.values.firstWhere(
        (t) => t.toString() == data['type'],
      ),
      headers: Map<String, String>.from(data['headers'] ?? {}),
      payload: data['payload'],
      context: data['context'] != null 
        ? RpcContext.fromJson(data['context'])
        : null,
    );
  }
}

class RabbitMQTransportOptions {
  final bool durable;
  final bool autoDelete;
  final bool persistent;
  final int prefetchCount;
  
  const RabbitMQTransportOptions({
    this.durable = true,
    this.autoDelete = false,
    this.persistent = true,
    this.prefetchCount = 10,
  });
}
```
  
  
### Конфигурация

```dart
// rabbitmq_config.dart
class RabbitMQConfig {
  static const String defaultConnectionString = 'amqp://guest:guest@localhost:5672/';
  
  static RpcRabbitMQTransport createReliableTransport({
    required String requestQueue,
    required String responseQueue,
    String? connectionString,
  }) {
    return RpcRabbitMQTransport(
      connectionString: connectionString ?? defaultConnectionString,
      requestQueue: requestQueue,
      responseQueue: responseQueue,
      options: RabbitMQTransportOptions(
        durable: true,       // Переживание перезапусков сервера
        autoDelete: false,   // Не удалять очереди автоматически
        persistent: true,    // Сохранение сообщений на диск
        prefetchCount: 50,   // Обрабатывать до 50 сообщений одновременно
      ),
    );
  }
  
  static RpcRabbitMQTransport createFastTransport({
    required String requestQueue,
    required String responseQueue,
    String? connectionString,
  }) {
    return RpcRabbitMQTransport(
      connectionString: connectionString ?? defaultConnectionString,
      requestQueue: requestQueue,
      responseQueue: responseQueue,
      options: RabbitMQTransportOptions(
        durable: false,      // Быстрее, но менее надежно
        autoDelete: true,    // Автоматическая очистка
        persistent: false,   // Только в памяти
        prefetchCount: 100,  // Высокая пропускная способность
      ),
    );
  }
}
```
  

### 3. Файловый транспорт

Транспорт использующий файловую систему для асинхронной связи:

### Файловый транспорт

```dart
// filesystem_transport.dart

class RpcFileSystemTransport implements RpcTransport {
  final String _basePath;
  final String _instanceId;
  final FileSystemTransportOptions _options;
  
  late Directory _inboxDir;
  late Directory _outboxDir;
  late StreamSubscription _watcher;
  
  final StreamController<RpcMessage> _messageController = StreamController.broadcast();
  bool _isConnected = false;
  
  RpcFileSystemTransport({
    required String basePath,
    String? instanceId,
    FileSystemTransportOptions? options,
  }) : _basePath = basePath,
       _instanceId = instanceId ?? _generateInstanceId(),
       _options = options ?? FileSystemTransportOptions();
  
  @override
  Stream<RpcMessage> get messageStream => _messageController.stream;
  
  @override
  bool get isConnected => _isConnected;
  
  @override
  Map<String, dynamic> get configuration => {
    'transport_type': 'filesystem',
    'base_path': _basePath,
    'instance_id': _instanceId,
    'polling_interval': _options.pollingInterval.inMilliseconds,
  };
  
  @override
  Future<void> connect() async {
    if (_isConnected) return;
    
    try {
      // Создание директорий
      _inboxDir = Directory(path.join(_basePath, 'inbox', _instanceId));
      _outboxDir = Directory(path.join(_basePath, 'outbox', _instanceId));
      
      await _inboxDir.create(recursive: true);
      await _outboxDir.create(recursive: true);
      
      // Начало наблюдения за входящими сообщениями
      _startWatching();
      
      _isConnected = true;
      print('Файловый транспорт подключен в $_basePath');
      
    } catch (e) {
      print('Не удалось подключить файловый транспорт: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> sendMessage(RpcMessage message) async {
    if (!_isConnected) {
      throw StateError('Транспорт не подключен');
    }
    
    try {
      final serialized = _serializeMessage(message);
      final fileName = '${message.id}_${DateTime.now().millisecondsSinceEpoch}.msg';
      final filePath = path.join(_outboxDir.path, fileName);
      
      final file = File(filePath);
      await file.writeAsString(serialized);
      
      // Перемещение в целевой inbox (атомарная операция)
      final targetPath = path.join(_basePath, 'inbox', 'target', fileName);
      await file.rename(targetPath);
      
    } catch (e) {
      print('Не удалось отправить сообщение: $e');
      rethrow;
    }
  }
  
  @override
  Future<void> close() async {
    if (!_isConnected) return;
    
    try {
      await _watcher.cancel();
      await _messageController.close();
      
      // Очистка директорий при настройке
      if (_options.cleanupOnClose) {
        await _inboxDir.delete(recursive: true);
        await _outboxDir.delete(recursive: true);
      }
      
      _isConnected = false;
      
    } catch (e) {
      print('Ошибка закрытия файлового транспорта: $e');
    }
  }
  
  void _startWatching() {
    // Опрос новых файлов (простая реализация)
    _watcher = Stream.periodic(_options.pollingInterval).listen((_) async {
      await _processIncomingFiles();
    });
  }
  
  Future<void> _processIncomingFiles() async {
    try {
      final files = _inboxDir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.msg'))
          .toList();
      
      for (final file in files) {
        try {
          final content = await file.readAsString();
          final message = _deserializeMessage(content);
          _messageController.add(message);
          
          // Архивирование или удаление обработанного файла
          if (_options.archiveProcessed) {
            final archivePath = path.join(_basePath, 'archive', path.basename(file.path));
            await file.rename(archivePath);
          } else {
            await file.delete();
          }
          
        } catch (e) {
          print('Не удалось обработать файл ${file.path}: $e');
          // Перемещение в директорию ошибок
          final errorPath = path.join(_basePath, 'error', path.basename(file.path));
          await file.rename(errorPath);
        }
      }
      
    } catch (e) {
      print('Ошибка обработки входящих файлов: $e');
    }
  }
  
  String _serializeMessage(RpcMessage message) {
    return jsonEncode({
      'id': message.id,
      'contract_name': message.contractName,
      'method_name': message.methodName,
      'type': message.type.toString(),
      'headers': message.headers,
      'payload': message.payload,
      'context': message.context?.toJson(),
      'timestamp': DateTime.now().toIso8601String(),
      'sender': _instanceId,
    });
  }
  
  RpcMessage _deserializeMessage(String rawMessage) {
    final data = jsonDecode(rawMessage) as Map<String, dynamic>;
    
    return RpcMessage(
      id: data['id'] as String,
      contractName: data['contract_name'] as String,
      methodName: data['method_name'] as String,
      type: RpcMessageType.values.firstWhere(
        (t) => t.toString() == data['type'],
      ),
      headers: Map<String, String>.from(data['headers'] ?? {}),
      payload: data['payload'],
      context: data['context'] != null 
        ? RpcContext.fromJson(data['context'])
        : null,
    );
  }
  
  static String _generateInstanceId() {
    return 'fs_${DateTime.now().millisecondsSinceEpoch}_${Platform.operatingSystem}';
  }
}

class FileSystemTransportOptions {
  final Duration pollingInterval;
  final bool cleanupOnClose;
  final bool archiveProcessed;
  final int maxFileAge;
  
  const FileSystemTransportOptions({
    this.pollingInterval = const Duration(seconds: 1),
    this.cleanupOnClose = false,
    this.archiveProcessed = true,
    this.maxFileAge = 3600, // 1 час в секундах
  });
}
```
  

## Продвинутые возможности

### Middleware транспорта

Добавление middleware для сквозных вопросов:

```dart
abstract class TransportMiddleware {
  Future<RpcMessage> onMessageSend(RpcMessage message, TransportNext next);
  Future<RpcMessage> onMessageReceive(RpcMessage message, TransportNext next);
}

class LoggingMiddleware implements TransportMiddleware {
  @override
  Future<RpcMessage> onMessageSend(RpcMessage message, TransportNext next) async {
print('Отправляем: ${message.contractName}.${message.methodName}');
final stopwatch = Stopwatch()..start();

try {
  final result = await next(message);
  stopwatch.stop();
  print('Отправлено за ${stopwatch.elapsedMilliseconds}мс');
  return result;
} catch (e) {
  print('Ошибка отправки: $e');
  rethrow;
}
  }
  
  @override
  Future<RpcMessage> onMessageReceive(RpcMessage message, TransportNext next) async {
print('Получено: ${message.contractName}.${message.methodName}');
return await next(message);
  }
}

class CompressionMiddleware implements TransportMiddleware {
  @override
  Future<RpcMessage> onMessageSend(RpcMessage message, TransportNext next) async {
// Сжатие больших полезных нагрузок
if (_shouldCompress(message.payload)) {
  final compressed = await _compressPayload(message.payload);
  final compressedMessage = message.copyWith(
    payload: compressed,
    headers: {...message.headers, 'compressed': 'gzip'},
  );
  return await next(compressedMessage);
}
return await next(message);
  }
  
  @override
  Future<RpcMessage> onMessageReceive(RpcMessage message, TransportNext next) async {
// Распаковка при необходимости
if (message.headers['compressed'] == 'gzip') {
  final decompressed = await _decompressPayload(message.payload);
  final decompressedMessage = message.copyWith(payload: decompressed);
  return await next(decompressedMessage);
}
return await next(message);
  }
}
```

### Фабрика транспортов

Создание фабрики для управления различными типами транспортов:

```dart
class TransportFactory {
  static final Map<String, TransportBuilder> _builders = {};
  
  static void registerTransport<T extends RpcTransport>(
String name,
TransportBuilder<T> builder,
  ) {
_builders[name] = builder;
  }
  
  static RpcTransport create(String name, Map<String, dynamic> config) {
final builder = _builders[name];
if (builder == null) {
  throw ArgumentError('Неизвестный тип транспорта: $name');
}
return builder(config);
  }
  
  static void registerDefaultTransports() {
registerTransport('redis', (config) => RpcRedisTransport(
  redis: config['redis'],
  requestChannel: config['request_channel'],
  responseChannel: config['response_channel'],
));

registerTransport('rabbitmq', (config) => RpcRabbitMQTransport(
  connectionString: config['connection_string'],
  requestQueue: config['request_queue'],
  responseQueue: config['response_queue'],
));

registerTransport('filesystem', (config) => RpcFileSystemTransport(
  basePath: config['base_path'],
  instanceId: config['instance_id'],
));
  }
}

typedef TransportBuilder<T extends RpcTransport> = T Function(Map<String, dynamic> config);

// Использование
void main() {
  TransportFactory.registerDefaultTransports();
  
  final transport = TransportFactory.create('redis', {
'redis': redisConnection,
'request_channel': 'rpc_requests',
'response_channel': 'rpc_responses',
  });
}
```

## Тестирование пользовательских транспортов

### Тестовый набор транспорта

Создание комплексных тестов для вашего пользовательского транспорта:

```dart
// transport_test_suite.dart

abstract class TransportTestSuite {
  RpcTransport createClientTransport();
  RpcTransport createServerTransport();
  
  void runTests() {
group('Тесты транспорта', () {
  late RpcTransport clientTransport;
  late RpcTransport serverTransport;
  
  setUp(() async {
    clientTransport = createClientTransport();
    serverTransport = createServerTransport();
    await clientTransport.connect();
    await serverTransport.connect();
  });
  
  tearDown(() async {
    await clientTransport.close();
    await serverTransport.close();
  });
  
  test('должен успешно подключиться', () {
    expect(clientTransport.isConnected, isTrue);
    expect(serverTransport.isConnected, isTrue);
  });
  
  test('должен отправлять и получать сообщения', () async {
    final completer = Completer<RpcMessage>();
    
    serverTransport.messageStream.listen((message) {
      completer.complete(message);
    });
    
    final testMessage = RpcMessage(
      id: 'test-123',
      contractName: 'TestContract',
      methodName: 'testMethod',
      type: RpcMessageType.request,
      payload: {'test': 'data'},
    );
    
    await clientTransport.sendMessage(testMessage);
    
    final receivedMessage = await completer.future.timeout(Duration(seconds: 5));
    
    expect(receivedMessage.id, equals(testMessage.id));
    expect(receivedMessage.contractName, equals(testMessage.contractName));
    expect(receivedMessage.methodName, equals(testMessage.methodName));
  });
  
  test('должен обрабатывать большие сообщения', () async {
    final largePayload = List.generate(10000, (i) => 'data_$i');
    
    final completer = Completer<RpcMessage>();
    serverTransport.messageStream.listen((message) {
      completer.complete(message);
    });
    
    final largeMessage = RpcMessage(
      id: 'large-test',
      contractName: 'TestContract',
      methodName: 'testLarge',
      type: RpcMessageType.request,
      payload: largePayload,
    );
    
    await clientTransport.sendMessage(largeMessage);
    final received = await completer.future.timeout(Duration(seconds: 10));
    
    expect(received.payload, equals(largePayload));
  });
  
  test('должен корректно обрабатывать сбои соединения', () async {
    await clientTransport.close();
    
    expect(() => clientTransport.sendMessage(RpcMessage(
      id: 'fail-test',
      contractName: 'Test',
      methodName: 'test',
      type: RpcMessageType.request,
    )), throwsStateError);
  });
});
  }
}

// Пример использования для Redis транспорта
class RedisTransportTest extends TransportTestSuite {
  @override
  RpcTransport createClientTransport() {
return RpcRedisTransport(
  redis: RedisConnection(),
  requestChannel: 'test_requests',
  responseChannel: 'test_responses_client',
);
  }
  
  @override
  RpcTransport createServerTransport() {
return RpcRedisTransport(
  redis: RedisConnection(),
  requestChannel: 'test_requests',
  responseChannel: 'test_responses_server',
);
  }
}

void main() {
  RedisTransportTest().runTests();
}
```

## Лучшие практики

### 1. Обработка ошибок

Реализация надежной обработки ошибок:

```dart
class RobustCustomTransport implements RpcTransport {
  @override
  Future<void> sendMessage(RpcMessage message) async {
int retryCount = 0;
const maxRetries = 3;

while (retryCount < maxRetries) {
  try {
    await _doSendMessage(message);
    return;
  } on TransportException catch (e) {
    retryCount++;
    if (retryCount >= maxRetries) rethrow;
    
    await Future.delayed(Duration(seconds: retryCount));
    print('Повторная попытка отправки (попытка $retryCount): ${e.message}');
  }
}
  }
  
  void _handleError(dynamic error, StackTrace stackTrace) {
if (error is ConnectionException) {
  _handleConnectionError(error);
} else if (error is SerializationException) {
  _handleSerializationError(error);
} else {
  _handleUnknownError(error, stackTrace);
}
  }
}
```

### 2. Мониторинг производительности

Добавление мониторинга производительности:

```dart
class MonitoredTransport implements RpcTransport {
  final RpcTransport _underlying;
  final TransportMetrics _metrics = TransportMetrics();
  
  MonitoredTransport(this._underlying);
  
  @override
  Future<void> sendMessage(RpcMessage message) async {
final stopwatch = Stopwatch()..start();

try {
  await _underlying.sendMessage(message);
  stopwatch.stop();
  
  _metrics.recordSendSuccess(stopwatch.elapsed);
} catch (e) {
  stopwatch.stop();
  _metrics.recordSendFailure(stopwatch.elapsed, e);
  rethrow;
}
  }
  
  TransportMetrics get metrics => _metrics;
}

class TransportMetrics {
  int _messagesSent = 0;
  int _messagesReceived = 0;
  int _sendFailures = 0;
  int _receiveFailures = 0;
  
  final List<Duration> _sendLatencies = [];
  final List<Duration> _receiveLatencies = [];
  
  void recordSendSuccess(Duration latency) {
_messagesSent++;
_sendLatencies.add(latency);
_trimLatencies();
  }
  
  void recordSendFailure(Duration latency, dynamic error) {
_sendFailures++;
_sendLatencies.add(latency);
_trimLatencies();
  }
  
  double get averageSendLatency {
if (_sendLatencies.isEmpty) return 0.0;
final total = _sendLatencies.fold(Duration.zero, (a, b) => a + b);
return total.inMicroseconds / _sendLatencies.length / 1000.0; // мс
  }
  
  double get successRate {
final total = _messagesSent + _sendFailures;
return total > 0 ? _messagesSent / total : 0.0;
  }
  
  void _trimLatencies() {
// Сохранение только недавних измерений
const maxSamples = 1000;
if (_sendLatencies.length > maxSamples) {
  _sendLatencies.removeAt(0);
}
  }
}
```

### 3. Управление конфигурацией

Использование структурированной конфигурации:

```dart
class TransportConfig {
  final String type;
  final Map<String, dynamic> settings;
  final Duration connectionTimeout;
  final Duration messageTimeout;
  final int maxRetries;
  final bool enableMetrics;
  
  const TransportConfig({
required this.type,
this.settings = const {},
this.connectionTimeout = const Duration(seconds: 30),
this.messageTimeout = const Duration(seconds: 60),
this.maxRetries = 3,
this.enableMetrics = true,
  });
  
  factory TransportConfig.fromJson(Map<String, dynamic> json) {
return TransportConfig(
  type: json['type'] as String,
  settings: json['settings'] as Map<String, dynamic>? ?? {},
  connectionTimeout: Duration(seconds: json['connection_timeout'] ?? 30),
  messageTimeout: Duration(seconds: json['message_timeout'] ?? 60),
  maxRetries: json['max_retries'] ?? 3,
  enableMetrics: json['enable_metrics'] ?? true,
);
  }
  
  Map<String, dynamic> toJson() => {
'type': type,
'settings': settings,
'connection_timeout': connectionTimeout.inSeconds,
'message_timeout': messageTimeout.inSeconds,
'max_retries': maxRetries,
'enable_metrics': enableMetrics,
  };
}
```

Пользовательские транспорты дают вам максимальную гибкость для интеграции RPC Dart с любой системой связи или протоколом. Независимо от того, нужно ли вам работать с очередями сообщений, базами данных, файлами или экзотическими сетевыми протоколами, интерфейс транспорта предоставляет все инструменты, необходимые для создания надежной, высокопроизводительной RPC связи.
