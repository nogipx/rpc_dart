import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';
import 'package:minio/models.dart';
import 'package:minio/src/minio_client.dart' as minio_internal;
import 'package:xml/xml.dart' as xml;

import '../models.dart';
import 'i_blob_storage_adapter.dart';

typedef S3Clock = DateTime Function();

/// S3-compatible adapter (works with AWS S3, MinIO, Ceph, etc).
///
/// Stores blobs as individual objects under `<prefix><collection>/<id>`.
/// Uses custom metadata to persist version/createdAt/updatedAt. Optimistic
/// concurrency is best-effort (checks current version before upload).
class S3BlobStorageAdapter implements IBlobStorageAdapter {
  S3BlobStorageAdapter({
    required Minio client,
    required this.bucket,
    String? prefix,
    S3Clock? clock,
  }) : _client = client,
       _prefix = _normalizePrefix(prefix),
       _clock = clock ?? DateTime.now;

  /// Convenience factory to create a MinIO/S3 client.
  factory S3BlobStorageAdapter.connect({
    required String bucket,
    String endPoint = 'localhost',
    int? port,
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    bool useSSL = true,
    String? prefix,
    S3Clock? clock,
    bool pathStyle = false,
  }) {
    final client = Minio(
      endPoint: endPoint,
      port: port,
      accessKey: accessKey,
      secretKey: secretKey,
      sessionToken: sessionToken,
      useSSL: useSSL,
      pathStyle: pathStyle,
    );
    return S3BlobStorageAdapter(
      client: client,
      bucket: bucket,
      prefix: prefix,
      clock: clock,
    );
  }

  final Minio _client;
  final String bucket;
  final String _prefix;
  final S3Clock _clock;
  minio_internal.MinioClient? _rawClient;

  static const _metaVersion = 'rpc-version';
  static const _metaCreatedAt = 'rpc-created-at';
  static const _metaUpdatedAt = 'rpc-updated-at';
  static const _defaultPresignTtlSeconds = 3600;

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    final key = _objectKey(collection, id);
    try {
      final stat = await _client.statObject(bucket, key);
      final tags = await _getObjectTags(key);
      final url = await _presignedUrl(key);
      return _descriptorFromStat(
        collection,
        id,
        stat,
        downloadUrl: url,
        tags: tags,
      );
    } on MinioError catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  }

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async {
    final key = _objectKey(request.collection, request.id);
    final stat = await headBlob(request.collection, request.id);
    if (stat == null) return null;

    final offset = request.rangeStart ?? 0;
    int? length;
    if (request.rangeEnd != null) {
      if (request.rangeEnd! <= offset) return null;
      length = request.rangeEnd! - offset;
    }

    final stream = await _client.getPartialObject(bucket, key, offset, length);

    return BlobReadResult(
      descriptor: stat,
      bytes: stream.map((chunk) => Uint8List.fromList(chunk)),
      rangeStart: request.rangeStart,
      rangeEnd: request.rangeEnd,
    );
  }

  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) async {
    final id = request.id ?? _generateId();
    final existing = await headBlob(request.collection, id);
    if (existing == null && request.expectedVersion != null) {
      throw StateError(
        'Expected version ${request.expectedVersion} for $id but blob is missing.',
      );
    }
    if (existing != null &&
        request.expectedVersion != null &&
        existing.version != request.expectedVersion) {
      throw StateError(
        'Version mismatch for $id: expected ${request.expectedVersion}, '
        'actual ${existing.version}.',
      );
    }

    final collected = await _collectBytes(
      request.bytes,
      declaredLength: request.length,
    );
    if (request.checksum != null) {
      _verifyChecksum(
        collected,
        request.checksum!,
        algorithm: request.checksumAlgorithm,
      );
    }

    final now = _clock().toUtc();
    final createdAt = existing?.createdAt ?? now;
    final version = (existing?.version ?? 0) + 1;
    final metadata = <String, String>{
      _metaVersion: version.toString(),
      _metaCreatedAt: createdAt.toIso8601String(),
      _metaUpdatedAt: now.toIso8601String(),
      if (request.contentType != null) 'content-type': request.contentType!,
      if (request.metadata.isNotEmpty) ...request.metadata,
    };

    final key = _objectKey(request.collection, id);
    await _client.putObject(
      bucket,
      key,
      Stream.value(collected),
      size: collected.length,
      metadata: metadata,
    );

    return BlobWriteResult(
      descriptor: BlobDescriptor(
        id: id,
        collection: request.collection,
        length: collected.length,
        version: version,
        createdAt: createdAt,
        updatedAt: now,
        contentType: request.contentType,
        checksum: _etagLikeChecksum(collected),
        metadata: request.metadata,
        downloadUrl: await _presignedUrl(key),
      ),
    );
  }

  @override
  Future<bool> deleteBlob(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    final existing = await headBlob(collection, id);
    if (existing == null) return false;
    if (expectedVersion != null && existing.version != expectedVersion) {
      throw StateError(
        'Version mismatch for $id: expected $expectedVersion, actual ${existing.version}.',
      );
    }
    final key = _objectKey(collection, id);
    await _client.removeObject(bucket, key);
    return true;
  }

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    final prefix = '$_prefix${request.collection}/';
    final cursor = request.cursor == null || request.cursor!.isEmpty
        ? null
        : utf8.decode(base64Url.decode(request.cursor!));
    final items = <BlobDescriptor>[];
    String? nextCursor;
    await for (final chunk in _client.listObjects(
      bucket,
      prefix: prefix,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final objKey = object.key ?? '';
        if (objKey.isEmpty) continue;
        if (cursor != null && objKey.compareTo(cursor) <= 0) {
          continue;
        }
        if (!objKey.startsWith(prefix)) continue;
        final id = objKey.substring(prefix.length);
        if (request.prefix != null &&
            request.prefix!.isNotEmpty &&
            !id.startsWith(request.prefix!)) {
          continue;
        }
        final head = await headBlob(request.collection, id);
        if (head == null) continue;
        items.add(head);
        if (items.length == request.limit) {
          nextCursor = base64Url.encode(utf8.encode(objKey));
          break;
        }
      }
      if (nextCursor != null) break;
    }
    return ListBlobsResponse(items: items, nextCursor: nextCursor);
  }

  @override
  Future<List<String>> listCollections() async {
    final collections = <String>{};
    await for (final chunk in _client.listObjects(
      bucket,
      prefix: _prefix,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final key = object.key ?? '';
        if (!key.startsWith(_prefix)) continue;
        final remainder = key.substring(_prefix.length);
        final slashIndex = remainder.indexOf('/');
        if (slashIndex <= 0) continue;
        collections.add(remainder.substring(0, slashIndex));
      }
    }
    return collections.toList()..sort();
  }

  @override
  Future<void> dispose() async {
    // Minio client has no explicit close.
  }

  BlobDescriptor _descriptorFromStat(
    String collection,
    String id,
    StatObjectResult stat, {
    String? downloadUrl,
    Map<String, String> tags = const {},
  }) {
    final meta = <String, String>{};
    final rawMeta = stat.metaData ?? const <String, String?>{};
    // MinIO returns metadata with lowercase keys; normalize.
    rawMeta.forEach((key, value) {
      if (value != null) {
        meta[key.toLowerCase()] = value;
      }
    });
    final createdAtRaw = meta[_metaCreatedAt] ?? meta['created-at'];
    final updatedAtRaw = meta[_metaUpdatedAt] ?? meta['updated-at'];
    final versionRaw = meta[_metaVersion] ?? meta['version'];

    final lastModified = (stat.lastModified ?? DateTime.now()).toUtc();
    final createdAt = createdAtRaw != null
        ? DateTime.parse(createdAtRaw).toUtc()
        : lastModified;
    final updatedAt = updatedAtRaw != null
        ? DateTime.parse(updatedAtRaw).toUtc()
        : lastModified;
    final version = int.tryParse(versionRaw ?? '') ?? 1;

    final userMetadata = Map<String, String>.from(meta)
      ..removeWhere(
        (key, _) =>
            key == _metaVersion ||
            key == _metaCreatedAt ||
            key == _metaUpdatedAt ||
            key == 'content-type' ||
            key == 'etag',
      );

    if (tags.isNotEmpty) {
      tags.forEach((tagKey, tagValue) {
        userMetadata.putIfAbsent(tagKey, () => tagValue);
      });
    }

    return BlobDescriptor(
      id: id,
      collection: collection,
      length: stat.size ?? 0,
      version: version,
      createdAt: createdAt,
      updatedAt: updatedAt,
      contentType: meta['content-type'],
      checksum: stat.etag,
      metadata: userMetadata,
      downloadUrl: downloadUrl,
    );
  }

  String _objectKey(String collection, String id) =>
      '$_prefix$collection/$id'.replaceAll('//', '/');

  static String _normalizePrefix(String? prefix) {
    if (prefix == null || prefix.isEmpty) return '';
    var value = prefix;
    if (!value.endsWith('/')) value = '$value/';
    if (value.startsWith('/')) value = value.substring(1);
    return value;
  }

  static Future<Uint8List> _collectBytes(
    Stream<Uint8List> stream, {
    int? declaredLength,
  }) async {
    final chunks = <int>[];
    var total = 0;
    await for (final chunk in stream) {
      total += chunk.length;
      chunks.addAll(chunk);
    }
    if (declaredLength != null && total != declaredLength) {
      throw StateError(
        'Length mismatch: declared=$declaredLength actual=$total bytes',
      );
    }
    return Uint8List.fromList(chunks);
  }

  static void _verifyChecksum(
    Uint8List bytes,
    String expected, {
    ChecksumAlgorithm? algorithm,
  }) {
    final algo = algorithm ?? ChecksumAlgorithm.sha256;
    switch (algo) {
      case ChecksumAlgorithm.sha256:
        final digest = sha256.convert(bytes).toString();
        if (digest != expected.toLowerCase()) {
          throw StateError(
            'Checksum mismatch: expected $expected actual $digest',
          );
        }
    }
  }

  static bool _isNotFound(MinioError error) {
    if (error is MinioS3Error) {
      final code = error.error?.code;
      if (code != null && code.toLowerCase() == 'nosuchkey') return true;
      if (error.response?.statusCode == 404) return true;
    }
    final message = error.message ?? error.toString();
    return message.contains('NoSuchKey') || message.contains('404');
  }

  static String _generateId() => _randomBase62(16);

  static const _alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

  static String _randomBase62(int length) {
    final random = Random.secure();
    final codeUnits = List<int>.generate(
      length,
      (_) => _alphabet.codeUnitAt(random.nextInt(_alphabet.length)),
    );
    return String.fromCharCodes(codeUnits);
  }

  static String _etagLikeChecksum(Uint8List bytes) {
    final digest = md5.convert(bytes).toString();
    return digest;
  }

  Future<String?> _presignedUrl(String key) async {
    try {
      return await _client.presignedGetObject(
        bucket,
        key,
        expires: _defaultPresignTtlSeconds,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _getObjectTags(String key) async {
    try {
      final client = _rawClient ??= minio_internal.MinioClient(_client);
      final response = await client.request(
        method: 'GET',
        bucket: bucket,
        object: key,
        resource: 'tagging',
      );
      if (response.statusCode != 200) return const <String, String>{};

      final document = xml.XmlDocument.parse(response.body);
      final tags = <String, String>{};
      for (final tag in document.findAllElements('Tag')) {
        final tagKey = tag.getElement('Key')?.text;
        final tagValue = tag.getElement('Value')?.text;
        if (tagKey != null && tagValue != null) {
          tags[tagKey] = tagValue;
        }
      }
      return tags;
    } on MinioError catch (e) {
      if (_isNotFound(e)) return const <String, String>{};
      rethrow;
    } catch (_) {
      return const <String, String>{};
    }
  }
}
