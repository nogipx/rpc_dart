import 'dart:async';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_blob/rpc_dart_blob.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

void main() {
  runApp(const BlobClientApp());
}

class BlobClientApp extends StatelessWidget {
  const BlobClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'rpc_dart_blob client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const BlobDashboardPage(),
    );
  }
}

enum ConnectionMode { inMemory, webSocket }

class BlobClientController {
  BlobServiceClient? _client;
  InMemoryBlobServiceEnvironment? _inMemoryEnv;
  IRpcTransport? _transport;

  BlobServiceClient? get client => _client;

  bool get isConnected => _client != null;

  Future<void> connectInMemory({String? databasePath}) async {
    await close();
    final storage = databasePath == null || databasePath.isEmpty
        ? SqliteBlobStorageAdapter.memory()
        // WAL создаёт .wal/.shm рядом с файлом, что ломается в песочнице macOS.
        // Для пользовательского файла предпочитаем обычный журнал.
        : SqliteBlobStorageAdapter.file(databasePath, enableWal: false);
    _inMemoryEnv = await BlobServiceFactory.inMemory(storage: storage);
    _client = _inMemoryEnv!.client;
  }

  Future<void> connectWebSocket(Uri uri) async {
    await close();
    final transport = RpcWebSocketCallerTransport.connect(uri);
    _transport = transport;
    _client = BlobServiceFactory.createClient(transport: transport);
  }

  Future<void> close() async {
    await _client?.close();
    await _transport?.close();
    await _inMemoryEnv?.server.close();
    await _inMemoryEnv?.clientTransport.close();
    await _inMemoryEnv?.serverTransport.close();
    _client = null;
    _transport = null;
    _inMemoryEnv = null;
  }
}

class BlobDashboardPage extends StatefulWidget {
  const BlobDashboardPage({super.key});

  @override
  State<BlobDashboardPage> createState() => _BlobDashboardPageState();
}

class _BlobDashboardPageState extends State<BlobDashboardPage> {
  final _controller = BlobClientController();
  final _wsUrlController = TextEditingController(
    text: 'ws://localhost:8080/ws',
  );
  final _collectionController = TextEditingController(text: 'default');
  final _idController = TextEditingController();
  final _metadataController = TextEditingController();

  ConnectionMode _mode = ConnectionMode.inMemory;
  bool _connecting = false;
  bool _busy = false;
  String _status = 'Нет активного соединения';
  String? _databasePath;

  List<String> _collections = const [];
  String? _selectedCollection;
  List<BlobDescriptor> _blobs = const [];
  String? _nextCursor;

  bool _attachChunkChecksums = false;

  @override
  void dispose() {
    _wsUrlController.dispose();
    _collectionController.dispose();
    _idController.dispose();
    _metadataController.dispose();
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('rpc_dart_blob Flutter клиент')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildConnectionCard(),
              const SizedBox(height: 12),
              _buildCollectionsCard(),
              const SizedBox(height: 12),
              _buildUploadCard(),
              const SizedBox(height: 12),
              _buildBlobsCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<ConnectionMode>(
                    value: _mode,
                    decoration: const InputDecoration(
                      labelText: 'Транспорт',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: ConnectionMode.inMemory,
                        child: Text('In-memory demo'),
                      ),
                      DropdownMenuItem(
                        value: ConnectionMode.webSocket,
                        child: Text('WebSocket RPC'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _mode = value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                if (_mode == ConnectionMode.webSocket)
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _wsUrlController,
                      decoration: const InputDecoration(
                        labelText: 'WebSocket URL (ws/wss)',
                        border: OutlineInputBorder(),
                        hintText: 'ws://localhost:8080/ws',
                      ),
                    ),
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
            if (_mode == ConnectionMode.inMemory) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _databasePath == null || _databasePath!.isEmpty
                          ? 'Используется временная in-memory база'
                          : 'База: ${_databasePath}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _pickDatabaseFile,
                    icon: const Icon(Icons.storage),
                    label: const Text('Выбрать файл БД'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Сбросить на in-memory',
                    onPressed: _databasePath == null || _databasePath!.isEmpty
                        ? null
                        : () => setState(() => _databasePath = ''),
                    icon: const Icon(Icons.clear),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: _connecting ? null : _connect,
                  icon: _connecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Подключиться'),
                ),
                OutlinedButton.icon(
                  onPressed: _controller.isConnected ? _disconnect : null,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Отключить'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              style: TextStyle(
                color: _controller.isConnected ? Colors.green : Colors.orange,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCollectionsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _collectionController,
                    decoration: const InputDecoration(
                      labelText: 'Текущая коллекция',
                      border: OutlineInputBorder(),
                      helperText:
                          'Можно задать новую строку — коллекция появится при загрузке',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _controller.isConnected
                      ? () => _loadBlobs(_collectionController.text.trim())
                      : null,
                  icon: const Icon(Icons.check),
                  label: const Text('Активировать'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Коллекции',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                IconButton(
                  onPressed: _controller.isConnected ? _loadCollections : null,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Обновить список',
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_collections.isEmpty)
              const Text('Нет данных. Подключитесь и нажмите обновить.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _collections
                    .map(
                      (c) => ChoiceChip(
                        label: Text(c),
                        selected: c == _selectedCollection,
                        onSelected: (_) => _loadBlobs(c),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildUploadCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _idController,
                    decoration: const InputDecoration(
                      labelText: 'ID блоба (необязательно)',
                      border: OutlineInputBorder(),
                      helperText: 'Если пусто — сервер сгенерирует id',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: _attachChunkChecksums,
                      onChanged: (v) =>
                          setState(() => _attachChunkChecksums = v),
                    ),
                    const Text('Чексуммы чанков'),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _metadataController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Метаданные (key=value на строку)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _controller.isConnected && !_busy
                  ? _pickAndUpload
                  : null,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.file_upload),
              label: const Text('Выбрать файл и загрузить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlobsCard() {
    final hasData = _blobs.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Текущая коллекция: ${_selectedCollection ?? 'не выбрана'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text('Записей: ${_blobs.length}'),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    IconButton(
                      onPressed:
                          _controller.isConnected && _selectedCollection != null
                          ? () => _loadBlobs(_selectedCollection)
                          : null,
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Обновить список',
                    ),
                    if (_nextCursor != null)
                      TextButton(
                        onPressed: () => _loadBlobs(
                          _selectedCollection,
                          cursor: _nextCursor,
                          append: true,
                        ),
                        child: const Text('Загрузить ещё'),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(minHeight: 4),
            const SizedBox(height: 12),
            if (!hasData)
              const Text('Пока нет записей в выбранной коллекции.')
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 16,
                  headingRowHeight: 44,
                  dataRowMinHeight: 44,
                  dataRowMaxHeight: 72,
                  columns: const [
                    DataColumn(label: Text('ID')),
                    DataColumn(label: Text('Размер')),
                    DataColumn(label: Text('MIME')),
                    DataColumn(label: Text('Версия')),
                    DataColumn(label: Text('Обновлён')),
                    DataColumn(label: Text('Метаданные')),
                    DataColumn(label: Text('Действия')),
                  ],
                  rows: _blobs.map((blob) {
                    return DataRow(
                      cells: [
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: Text(
                              blob.id,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        DataCell(Text('${blob.length} байт')),
                        DataCell(Text(blob.contentType ?? '—')),
                        DataCell(Text('v${blob.version}')),
                        DataCell(Text(_formatDate(blob.updatedAt))),
                        DataCell(
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 280),
                            child: Text(
                              _formatMetadata(blob.metadata),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 3,
                            ),
                          ),
                        ),
                        DataCell(
                          Wrap(
                            spacing: 8,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.download),
                                tooltip: 'Скачать в память',
                                onPressed: () => _downloadBlob(blob),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Удалить',
                                onPressed: () => _deleteBlob(blob),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDatabaseFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Выберите файл SQLite хранилища',
      type: FileType.any,
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final file = result.files.first.path;
    if (file == null || file.isEmpty) {
      _showSnack('Невозможно использовать выбранный файл', isError: true);
      return;
    }
    setState(() => _databasePath = file);
  }

  Future<void> _connect() async {
    if (_controller.isConnected) return;
    setState(() {
      _connecting = true;
      _status = 'Подключение...';
    });

    try {
      if (_mode == ConnectionMode.inMemory) {
        final preparedPath = await _prepareDatabasePath(_databasePath);
        String? status;
        try {
          await _controller.connectInMemory(databasePath: preparedPath);
          status = _databasePath == null || _databasePath!.isEmpty
              ? 'In-memory сервер запущен'
              : 'Запущено с БД $_databasePath';
        } catch (error) {
          final isPathProvided =
              preparedPath != null && preparedPath.trim().isNotEmpty;
          final isPermissionIssue = error.toString().contains('code 14');
          if (isPathProvided && isPermissionIssue) {
            final fallback = await _copyDbToTemp(preparedPath!);
            if (fallback != null) {
              await _controller.connectInMemory(databasePath: fallback);
              status = 'БД скопирована в sandbox: $fallback';
              _showSnack(
                'Исходный файл недоступен, работаем с копией: $fallback',
              );
            }
          }
          if (status == null) rethrow;
        }
        _status = status ?? 'In-memory сервер запущен';
      } else {
        final raw = _wsUrlController.text.trim();
        if (raw.isEmpty) throw const FormatException('Укажите URL');
        final uri = Uri.parse(raw);
        if (!uri.hasScheme || !uri.hasAuthority) {
          throw const FormatException('Неверный URL');
        }
        await _controller.connectWebSocket(uri);
        _status = 'Подключено к $raw';
      }
      await _loadCollections();
    } catch (error) {
      _status = 'Ошибка подключения: $error';
      _showSnack('Не удалось подключиться: $error', isError: true);
    } finally {
      if (mounted) {
        setState(() => _connecting = false);
      }
    }
  }

  /// Ensures the chosen DB file and its directory exist before opening SQLite.
  Future<String?> _prepareDatabasePath(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final file = io.File(path);
      await file.parent.create(recursive: true);
      if (!await file.exists()) {
        await file.create();
      }
      return file.path;
    } catch (error) {
      _showSnack('Не удалось подготовить файл БД: $error', isError: true);
      return null;
    }
  }

  /// Copies a database file into a writable temp dir when sandbox blocks access.
  Future<String?> _copyDbToTemp(String sourcePath) async {
    try {
      final source = io.File(sourcePath);
      if (!await source.exists()) return null;
      final tempDir = await io.Directory.systemTemp.createTemp('rpc_blob_db_');
      final targetPath = p.join(tempDir.path, p.basename(sourcePath));
      await source.copy(targetPath);
      return targetPath;
    } catch (error) {
      _showSnack('Не удалось скопировать БД в sandbox: $error', isError: true);
      return null;
    }
  }

  Future<void> _disconnect() async {
    await _controller.close();
    if (!mounted) return;
    setState(() {
      _collections = const [];
      _blobs = const [];
      _selectedCollection = null;
      _status = 'Соединение закрыто';
    });
  }

  Future<void> _loadCollections() async {
    final client = _controller.client;
    if (client == null) return;
    try {
      final response = await client.listCollections();
      if (!mounted) return;
      setState(() {
        _collections = response.collections;
        if (_collections.isNotEmpty && _selectedCollection == null) {
          _selectedCollection = _collections.first;
        }
      });
      if (_selectedCollection != null) {
        await _loadBlobs(_selectedCollection);
      }
    } catch (error) {
      _showSnack('Ошибка загрузки коллекций: $error', isError: true);
    }
  }

  Future<void> _loadBlobs(
    String? collection, {
    String? cursor,
    bool append = false,
  }) async {
    final client = _controller.client;
    final target = collection?.trim();
    if (client == null || target == null || target.isEmpty) return;

    setState(() => _busy = true);
    try {
      final response = await client.list(
        target,
        cursor: cursor,
        includeMetadata: true,
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _selectedCollection = target;
        _nextCursor = response.nextCursor;
        _blobs = append ? [..._blobs, ...response.items] : response.items;
      });
    } catch (error) {
      _showSnack('Ошибка чтения коллекции: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndUpload() async {
    if (_selectedCollection == null || _selectedCollection!.isEmpty) {
      _showSnack('Выберите коллекцию перед загрузкой.', isError: true);
      return;
    }

    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;

    final metadata = _parseMetadata();
    final blobId = _idController.text.trim().isEmpty
        ? null
        : _idController.text.trim();
    final contentType = lookupMimeType(file.name);

    setState(() => _busy = true);
    try {
      final uploadStream = await _openFileStream(file);
      final checksum = await _computeChecksum(file);
      final response = await _controller.client!.putBytes(
        collection: _selectedCollection!,
        id: blobId ?? p.basename(file.name),
        bytes: uploadStream,
        length: file.size,
        contentType: contentType,
        checksum: checksum,
        attachChunkChecksums: _attachChunkChecksums,
        metadata: metadata,
      );
      _showSnack(
        'Загружено: ${response.descriptor.id} (${response.descriptor.length} байт)',
      );
      _idController.clear();
      await _loadBlobs(_selectedCollection);
    } catch (error) {
      _showSnack('Ошибка загрузки: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Stream<Uint8List>> _openFileStream(PlatformFile file) async {
    if (kIsWeb || file.path == null) {
      final bytes =
          file.bytes ??
          await file.readStream!
              .fold<BytesBuilder>(
                BytesBuilder(),
                (builder, chunk) => builder..add(chunk),
              )
              .then((builder) => builder.takeBytes());
      return Stream.value(bytes ?? Uint8List(0));
    }
    final ioFile = io.File(file.path!);
    return ioFile.openRead().map((chunk) => Uint8List.fromList(chunk));
  }

  Future<String?> _computeChecksum(PlatformFile file) async {
    try {
      if (kIsWeb || file.path == null) {
        final data =
            file.bytes ??
            await file.readStream!
                .fold<BytesBuilder>(
                  BytesBuilder(),
                  (builder, chunk) => builder..add(chunk),
                )
                .then((builder) => builder.takeBytes());
        return sha256.convert(data ?? Uint8List(0)).toString();
      }
      final digest = await sha256.bind(io.File(file.path!).openRead()).first;
      return digest.toString();
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _parseMetadata() {
    final lines = _metadataController.text.split('\n');
    final result = <String, String>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('=');
      if (parts.length >= 2) {
        result[parts.first.trim()] = parts.sublist(1).join('=').trim();
      }
    }
    return result;
  }

  String _formatMetadata(Map<String, String> metadata) {
    if (metadata.isEmpty) return '—';
    return metadata.entries.map((e) => '${e.key}=${e.value}').join(', ');
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal().toIso8601String();
    return local.split('.').first.replaceFirst('T', ' ');
  }

  Future<void> _downloadBlob(BlobDescriptor blob) async {
    final client = _controller.client;
    if (client == null) return;
    setState(() => _busy = true);
    try {
      final frames = await client.get(blob.collection, blob.id).toList();
      final buffer = BytesBuilder();
      for (final frame in frames) {
        buffer.add(frame.bytes);
      }
      final bytes = buffer.takeBytes();
      _showSnack('Загружено ${bytes.length} байт из ${blob.id}');
    } catch (error) {
      _showSnack('Ошибка скачивания: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteBlob(BlobDescriptor blob) async {
    final client = _controller.client;
    if (client == null) return;
    setState(() => _busy = true);
    try {
      await client.delete(
        blob.collection,
        blob.id,
        expectedVersion: blob.version,
      );
      _showSnack('Удалено: ${blob.id}');
      await _loadBlobs(blob.collection);
    } catch (error) {
      _showSnack('Ошибка удаления: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }
}
