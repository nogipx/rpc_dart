import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
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
        : SqliteBlobStorageAdapter.file(databasePath);
    _inMemoryEnv = await BlobServiceFactory.inMemory(storage: storage);
    _client = _inMemoryEnv!.client;
  }

  Future<void> connectWebSocket(Uri uri) async {
    await close();
    final transport = RpcWebSocketCallerTransport.connect(uri);
    _transport = transport;
    _client = BlobServiceFactory.createClient(
      transport: transport,
    );
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
  final _wsUrlController = TextEditingController(text: 'ws://localhost:8080/ws');
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
      appBar: AppBar(
        title: const Text('rpc_dart_blob Flutter клиент'),
      ),
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
                      helperText: 'Можно задать новую строку — коллекция появится при загрузке',
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
                      onChanged: (v) => setState(() => _attachChunkChecksums = v),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Блобов: ${_blobs.length}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    IconButton(
                      onPressed: _controller.isConnected && _selectedCollection != null
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
            if (_blobs.isEmpty)
              const Text('Пока нет записей в выбранной коллекции.')
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _blobs.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) {
                  final blob = _blobs[index];
                  return ListTile(
                    title: Text(blob.id),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Размер: ${blob.length} байт — ${blob.contentType ?? 'тип неизвестен'}'),
                        Text('Версия ${blob.version} • Обновлён: ${blob.updatedAt.toIso8601String()}'),
                        if (blob.metadata.isNotEmpty)
                          Text('Метаданные: ${blob.metadata}'),
                      ],
                    ),
                    trailing: Wrap(
                      spacing: 4,
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
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDatabaseFile() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Укажите файл SQLite для хранилища',
      fileName: 'blob_store.sqlite',
    );
    if (!mounted || path == null) return;
    setState(() => _databasePath = path);
  }

  Future<void> _connect() async {
    if (_controller.isConnected) return;
    setState(() {
      _connecting = true;
      _status = 'Подключение...';
    });

    try {
      if (_mode == ConnectionMode.inMemory) {
        await _controller.connectInMemory(databasePath: _databasePath);
        _status = _databasePath == null || _databasePath!.isEmpty
            ? 'In-memory сервер запущен'
            : 'Запущено с БД $_databasePath';
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
    final blobId = _idController.text.trim().isEmpty ? null : _idController.text.trim();
    final contentType = file.mimeType ?? lookupMimeType(file.name);

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
      _showSnack('Загружено: ${response.descriptor.id} (${response.descriptor.length} байт)');
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
      final bytes = file.bytes ?? await file.readStream!.fold<BytesBuilder>(
        BytesBuilder(),
        (builder, chunk) => builder..add(chunk),
      ).then((builder) => builder.takeBytes());
      return Stream.value(bytes);
    }
    final ioFile = io.File(file.path!);
    return ioFile.openRead().map((chunk) => Uint8List.fromList(chunk));
  }

  Future<String?> _computeChecksum(PlatformFile file) async {
    try {
      if (kIsWeb || file.path == null) {
        final data = file.bytes ?? await file.readStream!.fold<BytesBuilder>(
          BytesBuilder(),
          (builder, chunk) => builder..add(chunk),
        ).then((builder) => builder.takeBytes());
        return sha256.convert(data).toString();
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
      await client.delete(blob.collection, blob.id, expectedVersion: blob.version);
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
