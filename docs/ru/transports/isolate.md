<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Isolate транспорт

**Isolate транспорт** обеспечивает высокопроизводительную коммуникацию между Dart изолятами с возможностями передачи объектов без копирования. Он разработан для CPU-интенсивных приложений, которым требуется параллельная обработка с сохранением преимуществ прямого совместного использования объектов.

## Обзор

- **Передача объектов без копирования** – Прямая передача объектов между изолятами без накладных расходов на сериализацию, сохраняя производительность для больших структур данных.
  
- **Поддержка рабочих процессов** – Создание выделенных рабочих изолятов для CPU-интенсивных задач с сохранением отзывчивости основного изолята.
  
- **Параллельная обработка** – Распределение рабочей нагрузки между множественными изолятами для эффективного использования многоядерных систем.
  
- **Типобезопасность** – Полная информация о типах Dart сохраняется через границы изолятов, поддерживая безопасность на этапе компиляции.
  

## Ключевые возможности

### Производительность без копирования

В отличие от традиционной коммуникации изолятов, требующей передачи сообщений, Isolate транспорт может передавать объекты напрямую:

```dart
class LargeDataProcessor {
  // Обрабатываем массивные наборы данных без копирования
  Future<ProcessedData> processLargeDataset(LargeDataset dataset) async {
// Весь набор данных передаётся по ссылке в рабочий изолят
// Никакой сериализации, никакого копирования - только прямой доступ к объекту
return ProcessedData(
  results: dataset.records.map((record) => processRecord(record)).toList(),
  metadata: {
    'processed_at': DateTime.now(),
    'record_count': dataset.records.length,
    'processing_time_ms': processingTime.inMilliseconds,
  },
);
  }
}
```

### Управление рабочими изолятами

Автоматическое управление рабочими изолятами для параллельной обработки:

```dart
// Создаём пул рабочих изолятов
final transport = RpcIsolateTransport.workerPool(
  workerCount: Platform.numberOfProcessors,
  workerScript: 'worker_isolate.dart',
  options: IsolateTransportOptions(
enableZeroCopy: true,
maxMemoryUsage: 512 * 1024 * 1024, // 512МБ на рабочий
idleTimeout: Duration(minutes: 5),
  ),
);

final caller = RpcCallerEndpoint(transport: transport);
final processor = DataProcessorCaller(caller);

// Работа автоматически распределяется между доступными рабочими
final futures = List.generate(100, (i) async {
  return await processor.processChunk(DataChunk(id: i, data: generateData(i)));
});

final results = await Future.wait(futures);
// Все 100 чанков обработаны параллельно через рабочие изоляты
```

## Настройка и конфигурация

### Скрипт рабочего изолята

Создание выделенного рабочего скрипта для CPU-интенсивных операций:

### worker_isolate.dart

```dart
// worker_isolate.dart

void main(List<String> args, SendPort sendPort) async {
  // Создаём isolate транспорт для рабочего
  final transport = RpcIsolateWorkerTransport(sendPort);
  
  // Создаём responder эндпоинт
  final responder = RpcResponderEndpoint(transport: transport);
  
  // Регистрируем рабочие сервисы
  responder.registerServiceContract(DataProcessorResponder());
  responder.registerServiceContract(ImageProcessorResponder());
  responder.registerServiceContract(ComputationResponder());
  
  // Запускаем рабочий
  await responder.start();
  
  print('Рабочий изолят запущен с PID: ${Isolate.current.debugName}');
}

// CPU-интенсивный сервис обработки данных
class DataProcessorResponder extends RpcResponderContract {
  DataProcessorResponder() : super('DataProcessor');
  
  @override
  void setup() {
    addUnaryMethod<ProcessDataRequest, ProcessDataResponse>(
      methodName: 'processData',
      handler: _processData,
    );
    
    addUnaryMethod<ComputeRequest, ComputeResponse>(
      methodName: 'compute',
      handler: _compute,
    );
    
    addServerStreamMethod<BatchRequest, BatchResult>(
      methodName: 'processBatch',
      handler: _processBatch,
    );
  }
  
  Future<ProcessDataResponse> _processData(ProcessDataRequest request, {RpcContext? context}) async {
    // CPU-интенсивная обработка без блокирования основного изолята
    final results = <ProcessedItem>[];
    
    for (final item in request.items) {
      // Имитируем тяжёлые вычисления
      final processed = await _performHeavyComputation(item);
      results.add(processed);
    }
    
    return ProcessDataResponse(
      results: results,
      processingTimeMs: DateTime.now().difference(request.startTime).inMilliseconds,
      workerId: Isolate.current.debugName ?? 'unknown',
    );
  }
  
  Future<ComputeResponse> _compute(ComputeRequest request, {RpcContext? context}) async {
    // Математические вычисления
    final result = await _performMathematicalComputation(
      request.operation,
      request.parameters,
    );
    
    return ComputeResponse(
      result: result,
      metadata: {
        'computation_type': request.operation,
        'parameter_count': request.parameters.length,
        'worker_id': Isolate.current.debugName,
      },
    );
  }
  
  Stream<BatchResult> _processBatch(BatchRequest request, {RpcContext? context}) async* {
    final batchSize = request.batchSize ?? 10;
    
    for (int i = 0; i < request.items.length; i += batchSize) {
      final batch = request.items.skip(i).take(batchSize).toList();
      final processed = await _processBatchItems(batch);
      
      yield BatchResult(
        batchIndex: i ~/ batchSize,
        results: processed,
        progress: (i + batch.length) / request.items.length,
      );
    }
  }
  
  Future<ProcessedItem> _performHeavyComputation(DataItem item) async {
    // Имитируем CPU-интенсивную работу
    await Future.delayed(Duration(milliseconds: 50));
    
    return ProcessedItem(
      id: item.id,
      result: item.value * 2, // Упрощённое вычисление
      metadata: {
        'processed_by': Isolate.current.debugName,
        'computation_time': 50,
      },
    );
  }
}
```
  
  
### main_application.dart

```dart
// main_application.dart

class MainApplication {
  late RpcCallerEndpoint _caller;
  late DataProcessorCaller _dataProcessor;
  late RpcIsolateTransport _transport;
  
  Future<void> initialize() async {
    // Создаём isolate транспорт с пулом рабочих
    _transport = RpcIsolateTransport.workerPool(
      workerCount: Platform.numberOfProcessors,
      workerScript: 'worker_isolate.dart',
      options: IsolateTransportOptions(
        enableZeroCopy: true,
        loadBalancing: LoadBalancingStrategy.roundRobin,
        maxMemoryUsage: 256 * 1024 * 1024, // 256МБ на рабочий
        idleTimeout: Duration(minutes: 10),
        
        // Управление жизненным циклом рабочих
        onWorkerCreated: (workerId) => print('Рабочий создан: $workerId'),
        onWorkerTerminated: (workerId) => print('Рабочий завершён: $workerId'),
        onWorkerError: (workerId, error) => print('Ошибка рабочего: $workerId - $error'),
      ),
    );
    
    _caller = RpcCallerEndpoint(transport: _transport);
    _dataProcessor = DataProcessorCaller(_caller);
    
    await _transport.initialize();
    print('Инициализировано ${_transport.workerCount} рабочих изолятов');
  }
  
  Future<void> processLargeDataset() async {
    final dataset = generateLargeDataset(10000); // 10к элементов
    
    print('Обработка ${dataset.items.length} элементов...');
    final stopwatch = Stopwatch()..start();
    
    // Обрабатываем параллельно через рабочих
    final response = await _dataProcessor.processData(ProcessDataRequest(
      items: dataset.items,
      startTime: DateTime.now(),
    ));
    
    stopwatch.stop();
    
    print('Обработано ${response.results.length} элементов за ${stopwatch.elapsedMilliseconds}мс');
    print('Рабочий: ${response.workerId}');
    print('Время обработки: ${response.processingTimeMs}мс');
  }
  
  Future<void> close() async {
    await _caller.close();
    await _transport.close();
  }
}

void main() async {
  final app = MainApplication();
  
  try {
    await app.initialize();
    await app.processLargeDataset();
  } finally {
    await app.close();
  }
}
```
  
  
### contracts.dart

```dart
// contracts.dart

// Структуры данных для передачи без копирования
class DataItem {
  final String id;
  final double value;
  final Map<String, dynamic> metadata;
  
  DataItem({
    required this.id,
    required this.value,
    required this.metadata,
  });
}

class ProcessedItem {
  final String id;
  final double result;
  final Map<String, dynamic> metadata;
  
  ProcessedItem({
    required this.id,
    required this.result,
    required this.metadata,
  });
}

class ProcessDataRequest {
  final List<DataItem> items;
  final DateTime startTime;
  
  ProcessDataRequest({
    required this.items,
    required this.startTime,
  });
}

class ProcessDataResponse {
  final List<ProcessedItem> results;
  final int processingTimeMs;
  final String workerId;
  
  ProcessDataResponse({
    required this.results,
    required this.processingTimeMs,
    required this.workerId,
  });
}

class ComputeRequest {
  final String operation;
  final List<double> parameters;
  
  ComputeRequest({
    required this.operation,
    required this.parameters,
  });
}

class ComputeResponse {
  final double result;
  final Map<String, dynamic> metadata;
  
  ComputeResponse({
    required this.result,
    required this.metadata,
  });
}

class BatchRequest {
  final List<DataItem> items;
  final int? batchSize;
  
  BatchRequest({
    required this.items,
    this.batchSize,
  });
}

class BatchResult {
  final int batchIndex;
  final List<ProcessedItem> results;
  final double progress;
  
  BatchResult({
    required this.batchIndex,
    required this.results,
    required this.progress,
  });
}
```
  

## Случаи использования

### 1. Конвейер обработки изображений

Обработка изображений параллельно без блокирования UI:

```dart
class ImageProcessingPipeline {
  late RpcCallerEndpoint _caller;
  late ImageProcessorCaller _imageProcessor;
  
  Future<void> initializeWorkers() async {
final transport = RpcIsolateTransport.workerPool(
  workerCount: 4, // 4 рабочих изолята для обработки изображений
  workerScript: 'image_worker.dart',
  options: IsolateTransportOptions(
    enableZeroCopy: true,
    maxMemoryUsage: 1024 * 1024 * 1024, // 1ГБ на рабочий для изображений
  ),
);

_caller = RpcCallerEndpoint(transport: transport);
_imageProcessor = ImageProcessorCaller(_caller);
  }
  
  Future<List<ProcessedImage>> processImageBatch(List<RawImage> images) async {
print('Обработка ${images.length} изображений параллельно...');

// Обрабатываем все изображения одновременно через рабочих
final futures = images.map((image) async {
  return await _imageProcessor.processImage(ProcessImageRequest(
    image: image,
    filters: [
      ImageFilter.resize(width: 800, height: 600),
      ImageFilter.sharpen(intensity: 0.5),
      ImageFilter.colorCorrection(brightness: 1.1),
    ],
    outputFormat: ImageFormat.jpeg,
    quality: 85,
  ));
}).toList();

final results = await Future.wait(futures);
print('Обработано ${results.length} изображений');

return results.map((r) => r.processedImage).toList();
  }
  
  Stream<BatchProcessingUpdate> processImageDirectory(String directoryPath) async* {
final imageFiles = Directory(directoryPath).listSync()
    .where((f) => f.path.endsWith('.jpg') || f.path.endsWith('.png'))
    .toList();

const batchSize = 10;
int processed = 0;

for (int i = 0; i < imageFiles.length; i += batchSize) {
  final batch = imageFiles.skip(i).take(batchSize).toList();
  final images = await Future.wait(
    batch.map((file) => loadImageFromFile(file.path)),
  );
  
  final processedImages = await processImageBatch(images);
  processed += processedImages.length;
  
  yield BatchProcessingUpdate(
    processedCount: processed,
    totalCount: imageFiles.length,
    progress: processed / imageFiles.length,
    currentBatch: processedImages,
  );
}
  }
}
```

### 2. Аналитика данных и вычисления

Выполнение тяжёлой вычислительной работы в фоновых изолятах:

```dart
class DataAnalytics {
  late RpcCallerEndpoint _caller;
  late AnalyticsProcessorCaller _analyticsProcessor;
  
  Future<void> initializeAnalyticsCluster() async {
final transport = RpcIsolateTransport.workerPool(
  workerCount: Platform.numberOfProcessors,
  workerScript: 'analytics_worker.dart',
  options: IsolateTransportOptions(
    enableZeroCopy: true,
    loadBalancing: LoadBalancingStrategy.leastLoaded,
    
    // Настройки для аналитики
    memoryManagement: MemoryManagement(
      maxMemoryUsage: 2 * 1024 * 1024 * 1024, // 2ГБ на рабочий
      gcTriggerThreshold: 0.8,
      enableMemoryProfiling: true,
    ),
    
    performanceMonitoring: PerformanceMonitoring(
      enableCpuProfiling: true,
      enableLatencyTracking: true,
      reportInterval: Duration(seconds: 30),
    ),
  ),
);

_caller = RpcCallerEndpoint(transport: transport);
_analyticsProcessor = AnalyticsProcessorCaller(_caller);
  }
  
  Future<AnalyticsReport> generateReport(AnalyticsDataset dataset) async {
print('Генерация аналитического отчёта для ${dataset.records.length} записей...');

// Распределяем различные типы анализа между рабочими
final futures = [
  _analyticsProcessor.calculateStatistics(StatisticsRequest(
    data: dataset.numericalData,
    operations: [
      StatisticalOperation.mean,
      StatisticalOperation.median,
      StatisticalOperation.standardDeviation,
      StatisticalOperation.percentiles,
    ],
  )),
  
  _analyticsProcessor.performTimeSeriesAnalysis(TimeSeriesRequest(
    timeSeries: dataset.timeSeriesData,
    analysisTypes: [
      TimeSeriesAnalysis.trend,
      TimeSeriesAnalysis.seasonality,
      TimeSeriesAnalysis.correlation,
    ],
  )),
  
  _analyticsProcessor.runMachineLearning(MLRequest(
    features: dataset.features,
    labels: dataset.labels,
    algorithms: [
      MLAlgorithm.linearRegression,
      MLAlgorithm.randomForest,
      MLAlgorithm.clustering,
    ],
  )),
];

final results = await Future.wait(futures);

return AnalyticsReport(
  statistics: results[0] as StatisticsResult,
  timeSeriesAnalysis: results[1] as TimeSeriesResult,
  machineLearningResults: results[2] as MLResult,
  generatedAt: DateTime.now(),
  processingMetrics: await _getProcessingMetrics(),
);
  }
  
  Stream<RealtimeAnalytics> startRealtimeAnalysis(Stream<DataPoint> dataStream) async* {
final controller = StreamController<AnalyzeDataPointRequest>();

// Отправляем данные реального времени аналитическим рабочим
dataStream.listen((dataPoint) {
  controller.add(AnalyzeDataPointRequest(
    dataPoint: dataPoint,
    analysisConfig: RealtimeAnalysisConfig(
      enableAnomalyDetection: true,
      enableTrendAnalysis: true,
      windowSize: Duration(minutes: 5),
    ),
  ));
});

// Получаем результаты в реальном времени
await for (final result in _analyticsProcessor.analyzeRealtimeStream(controller.stream)) {
  yield RealtimeAnalytics(
    analysis: result,
    timestamp: DateTime.now(),
    workerId: result.workerId,
  );
}
  }
}
```

### 3. Научные вычисления

Высокопроизводительные научные вычисления:

```dart
class ScientificComputing {
  late RpcCallerEndpoint _caller;
  late ComputationEngineCaller _computationEngine;
  
  Future<void> initializeComputeCluster() async {
final transport = RpcIsolateTransport.workerPool(
  workerCount: Platform.numberOfProcessors * 2, // Избыточное обеспечение для CPU-нагруженной работы
  workerScript: 'scientific_worker.dart',
  options: IsolateTransportOptions(
    enableZeroCopy: true,
    
    // Оптимизация для научных вычислений
    computeOptimization: ComputeOptimization(
      enableVectorization: true,
      enableParallelMath: true,
      floatingPointPrecision: FloatingPointPrecision.double,
    ),
    
    // Управление памятью для больших наборов данных
    memoryManagement: MemoryManagement(
      maxMemoryUsage: 4 * 1024 * 1024 * 1024, // 4ГБ на рабочий
      enableLargeObjectHeap: true,
      gcStrategy: GCStrategy.throughput,
    ),
  ),
);

_caller = RpcCallerEndpoint(transport: transport);
_computationEngine = ComputationEngineCaller(_caller);
  }
  
  Future<SimulationResult> runMolecularDynamicsSimulation(MDSimulationRequest request) async {
print('Запуск моделирования молекулярной динамики с ${request.particles.length} частицами...');

// Распределяем шаги симуляции между рабочими
final timeSteps = request.totalTime ~/ request.timeStep;
final results = <MDStepResult>[];

for (int step = 0; step < timeSteps; step += 100) {
  final stepBatch = math.min(100, timeSteps - step);
  
  final batchFutures = List.generate(stepBatch, (i) async {
    return await _computationEngine.simulateTimeStep(MDStepRequest(
      particles: step == 0 ? request.particles : results.last.finalState,
      stepNumber: step + i,
      timeStep: request.timeStep,
      forces: request.forces,
      boundary: request.boundaryConditions,
    ));
  });
  
  final batchResults = await Future.wait(batchFutures);
  results.addAll(batchResults);
  
  // Отчёт о прогрессе
  final progress = (step + stepBatch) / timeSteps;
  print('Прогресс симуляции: ${(progress * 100).toStringAsFixed(1)}%');
}

return SimulationResult(
  steps: results,
  totalEnergy: results.last.totalEnergy,
  finalState: results.last.finalState,
  computationTime: results.fold(Duration.zero, (sum, r) => sum + r.computationTime),
);
  }
  
  Future<MatrixOperationResult> performLargeMatrixOperations(List<Matrix> matrices) async {
// Распределяем матричные операции между рабочими
final operations = [
  MatrixOperation.multiply,
  MatrixOperation.invert,
  MatrixOperation.eigenvalues,
  MatrixOperation.singularValueDecomposition,
];

final futures = <Future>[];

for (final matrix in matrices) {
  for (final operation in operations) {
    futures.add(_computationEngine.performMatrixOperation(MatrixRequest(
      matrix: matrix,
      operation: operation,
      precision: NumericalPrecision.high,
    )));
  }
}

final results = await Future.wait(futures);

return MatrixOperationResult(
  results: results.cast<MatrixResult>(),
  totalComputationTime: results.fold(
    Duration.zero, 
    (sum, r) => sum + (r as MatrixResult).computationTime,
  ),
);
  }
}
```

## Оптимизация производительности

### Управление памятью

Оптимизация использования памяти для крупномасштабной обработки:

```dart
class OptimizedIsolateTransport {
  static RpcIsolateTransport createOptimized({
required int workerCount,
required String workerScript,
  }) {
return RpcIsolateTransport.workerPool(
  workerCount: workerCount,
  workerScript: workerScript,
  options: IsolateTransportOptions(
    enableZeroCopy: true,
    
    // Оптимизация памяти
    memoryManagement: MemoryManagement(
      maxMemoryUsage: _calculateOptimalMemoryPerWorker(),
      gcTriggerThreshold: 0.7,
      enableMemoryProfiling: true,
      enableLargeObjectHeap: true,
      gcStrategy: GCStrategy.lowLatency,
    ),
    
    // Мониторинг производительности
    performanceMonitoring: PerformanceMonitoring(
      enableCpuProfiling: true,
      enableMemoryTracking: true,
      enableLatencyTracking: true,
      reportInterval: Duration(seconds: 30),
      onPerformanceReport: _handlePerformanceReport,
    ),
    
    // Балансировка нагрузки
    loadBalancing: LoadBalancingStrategy.adaptive,
    healthCheckInterval: Duration(seconds: 10),
    
    // Жизненный цикл рабочих
    workerLifecycle: WorkerLifecycle(
      idleTimeout: Duration(minutes: 5),
      maxWorkersPerCore: 2,
      enableWorkerRecycling: true,
      recycleAfterOperations: 10000,
    ),
  ),
);
  }
  
  static int _calculateOptimalMemoryPerWorker() {
final totalMemory = Platform.operatingSystemVersion.contains('memory') 
    ? _parseMemoryFromOS() 
    : 8 * 1024 * 1024 * 1024; // По умолчанию 8ГБ

final workerCount = Platform.numberOfProcessors;
return (totalMemory * 0.7) ~/ workerCount; // Используем 70% доступной памяти
  }
  
  static void _handlePerformanceReport(PerformanceReport report) {
print('Отчёт о производительности:');
print('  Использование CPU: ${report.cpuUsage.toStringAsFixed(1)}%');
print('  Использование памяти: ${report.memoryUsage ~/ (1024 * 1024)}МБ');
print('  Средняя задержка: ${report.averageLatency.inMilliseconds}мс');
print('  Пропускная способность: ${report.operationsPerSecond.toStringAsFixed(0)} оп/сек');

// Запускаем оптимизации на основе метрик
if (report.memoryUsage > report.maxMemoryUsage * 0.9) {
  print('Предупреждение: Высокое использование памяти, запуск GC');
  // Запускаем сборку мусора
}

if (report.averageLatency > Duration(seconds: 1)) {
  print('Предупреждение: Обнаружена высокая задержка');
  // Рассматриваем добавление больше рабочих или оптимизацию алгоритмов
}
  }
}
```

### Стратегии балансировки нагрузки

Реализация интеллектуального распределения работы:

```dart
class SmartLoadBalancer {
  final Map<String, WorkerMetrics> _workerMetrics = {};
  final Queue<PendingWork> _workQueue = Queue();
  
  String selectOptimalWorker(WorkType workType) {
switch (workType) {
  case WorkType.cpuIntensive:
    return _selectByCpuUsage();
  case WorkType.memoryIntensive:
    return _selectByMemoryUsage();
  case WorkType.balanced:
    return _selectByOverallLoad();
  default:
    return _selectRoundRobin();
}
  }
  
  String _selectByCpuUsage() {
return _workerMetrics.entries
    .where((entry) => entry.value.isHealthy)
    .reduce((a, b) => a.value.cpuUsage < b.value.cpuUsage ? a : b)
    .key;
  }
  
  String _selectByMemoryUsage() {
return _workerMetrics.entries
    .where((entry) => entry.value.isHealthy)
    .reduce((a, b) => a.value.memoryUsage < b.value.memoryUsage ? a : b)
    .key;
  }
  
  String _selectByOverallLoad() {
return _workerMetrics.entries
    .where((entry) => entry.value.isHealthy)
    .reduce((a, b) => a.value.overallLoad < b.value.overallLoad ? a : b)
    .key;
  }
  
  void updateWorkerMetrics(String workerId, WorkerMetrics metrics) {
_workerMetrics[workerId] = metrics;
  }
  
  Future<void> rebalanceWorkload() async {
final overloadedWorkers = _workerMetrics.entries
    .where((entry) => entry.value.overallLoad > 0.8)
    .map((entry) => entry.key)
    .toList();

if (overloadedWorkers.isNotEmpty) {
  await _redistributeWork(overloadedWorkers);
}
  }
}
```

## Лучшие практики

### 1. Оптимизируйте для операций без копирования

```dart
class ZeroCopyOptimizations {
  // ✅ Хорошо: Передавайте большие объекты напрямую
  Future<ProcessedData> processLargeData(LargeDataset dataset) async {
// Объект передаётся по ссылке, без копирования
return await processor.process(dataset);
  }
  
  // ❌ Избегайте: Ненужное преобразование данных перед передачей
  Future<ProcessedData> processLargeDataBad(LargeDataset dataset) async {
// Это создаёт ненужные копии
final serialized = dataset.toJson();
final reconstructed = LargeDataset.fromJson(serialized);
return await processor.process(reconstructed);
  }
  
  // ✅ Хорошо: Используйте потоки для больших коллекций
  Stream<ProcessedItem> processStreamingData(Stream<DataItem> items) async* {
await for (final item in items) {
  yield await processor.processItem(item);
}
  }
}
```

### 2. Правильно обрабатывайте жизненный цикл рабочих

```dart
class WorkerLifecycleManager {
  final Map<String, WorkerInfo> _workers = {};
  
  Future<void> initializeWorkers() async {
for (int i = 0; i < Platform.numberOfProcessors; i++) {
  await _createWorker('worker_$i');
}
  }
  
  Future<void> _createWorker(String workerId) async {
try {
  final worker = await IsolateWorker.spawn(
    'worker_script.dart',
    onExit: () => _handleWorkerExit(workerId),
    onError: (error) => _handleWorkerError(workerId, error),
  );
  
  _workers[workerId] = WorkerInfo(
    worker: worker,
    createdAt: DateTime.now(),
    taskCount: 0,
  );
  
} catch (e) {
  print('Не удалось создать рабочий $workerId: $e');
  rethrow;
}
  }
  
  void _handleWorkerExit(String workerId) {
print('Рабочий $workerId завершился, создаём замену...');
_workers.remove(workerId);
_createWorker(workerId);
  }
  
  void _handleWorkerError(String workerId, dynamic error) {
print('Ошибка рабочего $workerId: $error');
// Реализуем стратегию восстановления после ошибки
  }
  
  Future<void> gracefulShutdown() async {
print('Завершение работы ${_workers.length} рабочих...');

await Future.wait(_workers.values.map((info) async {
  await info.worker.terminate(graceful: true);
}));

_workers.clear();
  }
}
```

### 3. Мониторьте и профилируйте производительность

```dart
class IsolatePerformanceProfiler {
  final Map<String, List<Duration>> _latencyHistory = {};
  final Map<String, int> _throughputCounters = {};
  Timer? _reportTimer;
  
  void startProfiling() {
_reportTimer = Timer.periodic(Duration(seconds: 30), (_) {
  _generatePerformanceReport();
});
  }
  
  void recordLatency(String operation, Duration latency) {
_latencyHistory.putIfAbsent(operation, () => <Duration>[]);
_latencyHistory[operation]!.add(latency);

// Сохраняем только недавние измерения
if (_latencyHistory[operation]!.length > 1000) {
  _latencyHistory[operation]!.removeAt(0);
}
  }
  
  void recordThroughput(String operation) {
_throughputCounters[operation] = (_throughputCounters[operation] ?? 0) + 1;
  }
  
  void _generatePerformanceReport() {
print('\n=== Отчёт о производительности изолятов ===');

for (final operation in _latencyHistory.keys) {
  final latencies = _latencyHistory[operation]!;
  final avgLatency = latencies.fold(Duration.zero, (sum, l) => sum + l) ~/ latencies.length;
  final throughput = _throughputCounters[operation] ?? 0;
  
  print('$operation:');
  print('  Средняя задержка: ${avgLatency.inMilliseconds}мс');
  print('  Пропускная способность: ${throughput / 30} оп/сек');
  print('  Всего операций: $throughput');
}

// Сбрасываем счётчики
_throughputCounters.clear();
  }
  
  void stopProfiling() {
_reportTimer?.cancel();
_generatePerformanceReport();
  }
}
```

Isolate транспорт - идеальный выбор для CPU-интенсивных приложений, которым нужно поддерживать отзывчивость UI при выполнении тяжёлой вычислительной работы. Его возможности без копирования и управление рабочими делают его идеальным для научных вычислений, обработки данных и любых сценариев, где параллельная обработка может значительно улучшить производительность.
