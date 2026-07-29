// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The minio package does not export its signing/client helpers from a public
// library, so the S3 presign/sign implementation has to reach into its `src/`.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:minio/minio.dart';
import 'package:minio/models.dart';
// Prefixed too: the listing entry type is named `Object`, which is not a name
// worth introducing unprefixed into a file that also uses dart:core's.
import 'package:minio/models.dart' as minio;
import 'package:minio/src/minio_client.dart' as minio_internal;
import 'package:minio/src/minio_helpers.dart' as minio_helpers;
import 'package:minio/src/minio_sign.dart' as minio_sign;
import 'package:minio/src/utils.dart' as minio_utils;
import 'package:rpc_blob/rpc_blob.dart';
import 'package:xml/xml.dart' as xml;

typedef S3Clock = DateTime Function();

const int kDefaultPresignTtlSeconds = 3600;

class S3BlobStorageOptions {
  const S3BlobStorageOptions({
    this.bucketPrefix,
    this.useAdminApi = true,
    this.immutableObjects = false,
    this.createCollectionOnWrite = true,
    this.publicRead,
    this.clock,
    this.presignTtlSeconds,
    this.presignEndpoint,
    this.presignPort,
    this.presignUseSSL,
    this.presignPathStyle,
    this.presignRegion = 'us-east-1',
  });

  /// Optional prefix applied to all bucket names (e.g., "myapp-" makes
  /// collection "photos" map to bucket "myapp-photos").
  final String? bucketPrefix;

  /// Whether to use MinIO Admin API for [collectionSize] instead of listing
  /// all objects. Requires admin credentials. Defaults to true.
  final bool useAdminApi;

  /// Declares that objects are never rewritten under the same id — the case
  /// for any content-addressed store, where the id *is* the hash.
  ///
  /// Writes then skip the read that only existed to carry `version` and
  /// `createdAt` forward, which is one round trip per object. Version checks
  /// still work: an explicit `expectedVersion` takes the reading path.
  final bool immutableObjects;

  /// Create the bucket when a write lands on a missing one.
  ///
  /// The check itself is gone — writes no longer ask whether the bucket is
  /// there, they write and repair on the error. Turn this off to require
  /// [IBlobRepository.ensureCollection] up front.
  final bool createCollectionOnWrite;

  /// Whether objects are world-readable, deciding between a plain URL and a
  /// presigned one.
  ///
  /// Null keeps the old behaviour of asking the bucket for its policy — one
  /// request per descriptor built, so set this explicitly in anything that
  /// serves traffic. The deployment knows the answer; the adapter shouldn't
  /// have to discover it over the network.
  final bool? publicRead;

  /// Override the clock used for timestamps (primarily for tests).
  final S3Clock? clock;

  /// TTL for presigned download URLs in seconds (must be positive).
  final int? presignTtlSeconds;

  /// Override endpoint used only for presigned URLs (data plane stays on the
  /// primary client).
  final String? presignEndpoint;

  /// Override port used only for presigned URLs.
  final int? presignPort;

  /// Override scheme for presigned URLs.
  final bool? presignUseSSL;

  /// Override path style for presigned URLs.
  final bool? presignPathStyle;

  /// Region used for presigned URLs (required to avoid region lookups).
  final String? presignRegion;
}

/// S3-compatible adapter (works with AWS S3, MinIO, Ceph, etc).
///
/// Each collection maps to its own S3 bucket. The bucket is created
/// automatically on first write, mirroring the SQLite adapter's behaviour
/// of creating a table on demand.
///
/// Bucket name = [S3BlobStorageOptions.bucketPrefix] + normalised collection
/// name (lowercase alphanumeric + hyphens, 3–63 chars).
class S3BlobRepository implements IBlobRepository {
  S3BlobRepository({
    required Minio client,
    S3BlobStorageOptions options = const S3BlobStorageOptions(),
  }) : _client = client,
       _presignClient = _buildPresignClient(client, options),
       _bucketPrefix = _normalizeBucketPrefix(options.bucketPrefix),
       _useAdminApi = options.useAdminApi,
       _immutableObjects = options.immutableObjects,
       _createCollectionOnWrite = options.createCollectionOnWrite,
       _publicRead = options.publicRead,
       _clock = options.clock ?? DateTime.now,
       _presignTtlSeconds =
           options.presignTtlSeconds ?? kDefaultPresignTtlSeconds {
    assert(_presignTtlSeconds > 0, 'presignTtlSeconds must be positive');
  }

  /// Convenience factory to create a MinIO/S3 client.
  factory S3BlobRepository.connect({
    String endPoint = 'localhost',
    int? port,
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    bool useSSL = true,
    bool pathStyle = false,
    S3BlobStorageOptions options = const S3BlobStorageOptions(),
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
    return S3BlobRepository(client: client, options: options);
  }

  final Minio _client;
  final Minio _presignClient;
  final String _bucketPrefix;
  final bool _useAdminApi;
  final bool _immutableObjects;
  final bool _createCollectionOnWrite;
  final bool? _publicRead;
  final S3Clock _clock;
  final int _presignTtlSeconds;

  minio_internal.MinioClient? _rawClient;
  minio_internal.MinioClient? _presignRawClient;

  static const _metaVersion = 'rpc-version';
  static const _metaCreatedAt = 'rpc-created-at';
  static const _metaUpdatedAt = 'rpc-updated-at';

  // ---------------------------------------------------------------------------
  // IBlobRepository
  // ---------------------------------------------------------------------------

  @override
  Future<void> ensureCollection(String collection) async {
    await _ensureBucket(_bucketForCollection(collection));
  }

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    final bucketName = _bucketForCollection(collection);
    try {
      final stat = await _client.statObject(bucketName, id);
      final tags = await _getObjectTags(bucketName, id);
      final url = await _downloadUrl(bucketName, id);
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
    final bucketName = _bucketForCollection(request.collection);
    final stat = await headBlob(request.collection, request.id);
    if (stat == null) return null;

    final offset = request.rangeStart ?? 0;
    int? length;
    if (request.rangeEnd != null) {
      if (request.rangeEnd! <= offset) return null;
      length = request.rangeEnd! - offset;
    }

    final stream = await _client.getPartialObject(
      bucketName,
      request.id,
      offset,
      length,
    );

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
    final bucketName = _bucketForCollection(request.collection);

    // Read-before-write only when someone can act on the result: a version
    // check to enforce, or mutable objects whose version and createdAt have to
    // carry forward. For a content-addressed store neither applies, and this
    // was a round trip — three, in fact, since headBlob also fetches tags and
    // the bucket policy — on every chunk.
    final needsExisting =
        request.expectedVersion != null || !_immutableObjects;
    final existing =
        needsExisting ? await headBlob(request.collection, id) : null;
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

    await _putObject(bucketName, id, collected, metadata);

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
        downloadUrl: await _downloadUrl(bucketName, id),
      ),
    );
  }

  /// Writes the object, creating the bucket only if the write says it is
  /// missing.
  ///
  /// The old shape asked `bucketExists` before every write — a round trip to
  /// learn something that is true for all but the first write of a
  /// collection's life, and a check-then-act race besides. Repairing on the
  /// error is both cheaper and correct under concurrency: parallel writers
  /// that all see NoSuchBucket land on an idempotent create.
  Future<void> _putObject(
    String bucketName,
    String id,
    Uint8List bytes,
    Map<String, String> metadata,
  ) async {
    try {
      await _client.putObject(
        bucketName,
        id,
        Stream.value(bytes),
        size: bytes.length,
        metadata: metadata,
      );
    } on MinioError catch (e) {
      if (!_createCollectionOnWrite || !_isNoSuchBucket(e)) rethrow;
      await _ensureBucket(bucketName);
      await _client.putObject(
        bucketName,
        id,
        Stream.value(bytes),
        size: bytes.length,
        metadata: metadata,
      );
    }
  }

  static bool _isNoSuchBucket(MinioError error) {
    if (error is MinioS3Error) {
      final code = error.error?.code?.toLowerCase();
      if (code == 'nosuchbucket') return true;
    }
    final message = (error.message ?? error.toString()).toLowerCase();
    return message.contains('nosuchbucket') ||
        message.contains('does not exist');
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
    final bucketName = _bucketForCollection(collection);
    await _client.removeObject(bucketName, id);
    return true;
  }

  @override
  Future<Set<String>> deleteMany(String collection, List<String> ids) async {
    if (ids.isEmpty) return const {};
    final bucketName = _bucketForCollection(collection);
    if (!await _bucketExists(bucketName)) return const {};
    // DeleteObjects takes up to 1000 keys per request; without this a reclaim
    // of N chunks was N round trips, and in a cloud S3 N billed requests.
    for (var i = 0; i < ids.length; i += _deleteBatchSize) {
      final end = i + _deleteBatchSize;
      await _client.removeObjects(
        bucketName,
        ids.sublist(i, end < ids.length ? end : ids.length),
      );
    }
    // S3 reports no per-key existence for a batch delete, so the honest answer
    // is "all of them are gone now" rather than a subset we cannot determine.
    return ids.toSet();
  }

  /// S3's documented ceiling for one DeleteObjects request.
  static const _deleteBatchSize = 1000;

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    final bucketName = _bucketForCollection(request.collection);
    final exists = await _bucketExists(bucketName);
    if (!exists) return const ListBlobsResponse(items: []);

    final cursor = request.cursor == null || request.cursor!.isEmpty
        ? null
        : utf8.decode(base64Url.decode(request.cursor!));
    final items = <BlobDescriptor>[];
    String? nextCursor;

    await for (final chunk in _client.listObjects(
      bucketName,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final id = object.key ?? '';
        if (id.isEmpty) continue;
        if (cursor != null && id.compareTo(cursor) <= 0) continue;
        if (request.prefix != null &&
            request.prefix!.isNotEmpty &&
            !id.startsWith(request.prefix!)) {
          continue;
        }
        // The listing already carries size and mtime. Only a caller that asked
        // for metadata pays a HEAD per object — everything else was turning a
        // page of N into N+1 requests, which on a cloud S3 is N+1 billed ones.
        final BlobDescriptor? descriptor;
        if (request.includeMetadata) {
          descriptor = await headBlob(request.collection, id);
        } else {
          descriptor = _descriptorFromListing(request.collection, object);
        }
        if (descriptor == null) continue;
        items.add(descriptor);
        if (items.length == request.limit) {
          nextCursor = base64Url.encode(utf8.encode(id));
          break;
        }
      }
      if (nextCursor != null) break;
    }
    return ListBlobsResponse(items: items, nextCursor: nextCursor);
  }

  @override
  Future<List<String>> listCollections() async {
    final buckets = await _client.listBuckets();
    final collections = <String>[];
    for (final bucket in buckets) {
      final name = bucket.name;
      if (name.isEmpty) continue;
      if (_bucketPrefix.isNotEmpty && !name.startsWith(_bucketPrefix)) continue;
      collections.add(name.substring(_bucketPrefix.length));
    }
    return collections..sort();
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    final bucketName = _bucketForCollection(collection);
    final exists = await _bucketExists(bucketName);
    if (!exists) return false;

    // Remove all objects first (S3 requires empty bucket before deletion).
    await for (final chunk in _client.listObjects(
      bucketName,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final key = object.key;
        if (key == null) continue;
        await _client.removeObject(bucketName, key);
      }
    }
    await _client.removeBucket(bucketName);
    return true;
  }

  @override
  Future<int> collectionSize(String collection) async {
    final bucketName = _bucketForCollection(collection);
    final exists = await _bucketExists(bucketName);
    if (!exists) return 0;

    if (_useAdminApi) {
      final size = await _collectionSizeViaAdminApi(bucketName);
      if (size != null) return size;
    }

    // Fallback: list objects and sum sizes.
    var total = 0;
    await for (final chunk in _client.listObjects(
      bucketName,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        total += object.size ?? 0;
      }
    }
    return total;
  }

  /// Calls [GET /minio/admin/v3/storageinfo] and extracts the size of
  /// [bucketName]. Returns null if the call fails or the bucket is not found.
  Future<int?> _collectionSizeViaAdminApi(String bucketName) async {
    try {
      final minio = _client;
      final scheme = minio.useSSL ? 'https' : 'http';
      final uri = Uri(
        scheme: scheme,
        host: minio.endPoint,
        port: minio.port,
        path: '/minio/admin/v3/storageinfo',
      );

      final request = minio_internal.MinioRequest('GET', uri);
      final date = DateTime.now().toUtc();
      final region = minio.region ?? 'us-east-1';
      final payloadHash = minio_utils.sha256Hex('');

      request.headers.addAll({
        'host': uri.authority,
        'x-amz-date': minio_helpers.makeDateLong(date),
        'x-amz-content-sha256': payloadHash,
      });

      final authorization = minio_sign.signV4(minio, request, date, region);
      request.headers['authorization'] = authorization;

      final streamedResponse = await http.Client().send(request);
      if (streamedResponse.statusCode != 200) return null;

      final body = await streamedResponse.stream.bytesToString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      // Try bucketsUsage first, then bucketsSizes.
      final bucketsUsage = json['bucketsUsage'] as Map<String, dynamic>?;
      if (bucketsUsage != null) {
        final usage = bucketsUsage[bucketName] as Map<String, dynamic>?;
        if (usage != null) return usage['size'] as int? ?? 0;
      }

      final bucketsSizes = json['bucketsSizes'] as Map<String, dynamic>?;
      if (bucketsSizes != null) {
        return bucketsSizes[bucketName] as int? ?? 0;
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    // Minio client has no explicit close.
  }

  // ---------------------------------------------------------------------------
  // Bucket helpers
  // ---------------------------------------------------------------------------

  /// Returns the bucket name for a given collection.
  String _bucketForCollection(String collection) {
    return '$_bucketPrefix${_normalizeBucketName(collection)}';
  }

  /// Ensures the bucket exists, creating it if necessary.
  ///
  /// `bucketExists` then `makeBucket` is check-then-act: concurrent uploads to a
  /// new bucket (e.g. parallel startup uploads) all see it missing and all call
  /// `makeBucket`; the losers get BucketAlreadyOwnedByYou / BucketAlreadyExists.
  /// That means the bucket is there — treat it as idempotent success.
  Future<void> _ensureBucket(String bucketName) async {
    if (await _client.bucketExists(bucketName)) return;
    try {
      await _client.makeBucket(bucketName);
    } on MinioError catch (e) {
      if (_isBucketAlreadyOwned(e)) return;
      rethrow;
    }
  }

  static bool _isBucketAlreadyOwned(MinioError error) {
    if (error is MinioS3Error) {
      final code = error.error?.code?.toLowerCase();
      if (code == 'bucketalreadyownedbyyou' || code == 'bucketalreadyexists') {
        return true;
      }
    }
    final message = (error.message ?? error.toString()).toLowerCase();
    return message.contains('already own') ||
        message.contains('bucketalreadyownedbyyou') ||
        message.contains('bucketalreadyexists');
  }

  /// Checks whether a bucket exists.
  Future<bool> _bucketExists(String bucketName) =>
      _client.bucketExists(bucketName);

  // ---------------------------------------------------------------------------
  // Descriptor / metadata helpers
  // ---------------------------------------------------------------------------

  /// Builds a descriptor from a list entry, without a HEAD.
  ///
  /// Carries what S3 returns for a listing — size, mtime, ETag. `contentType`,
  /// user metadata and the stored version live in object metadata and stay
  /// absent here; a caller that needs them sets
  /// [ListBlobsRequest.includeMetadata], which is what that flag is for.
  BlobDescriptor _descriptorFromListing(String collection, minio.Object object) {
    final lastModified = (object.lastModified ?? _clock()).toUtc();
    return BlobDescriptor(
      id: object.key ?? '',
      collection: collection,
      length: object.size ?? 0,
      version: 1,
      createdAt: lastModified,
      updatedAt: lastModified,
      checksum: object.eTag?.replaceAll('"', ''),
    );
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
    rawMeta.forEach((key, value) {
      if (value != null) meta[key.toLowerCase()] = value;
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
    tags.forEach((k, v) => userMetadata.putIfAbsent(k, () => v));

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

  // ---------------------------------------------------------------------------
  // URL helpers
  // ---------------------------------------------------------------------------

  Future<String?> _downloadUrl(String bucketName, String key) async {
    final configured = _publicRead;
    if (configured != null) {
      return configured
          ? _publicUrl(bucketName, key)
          : _presignedUrl(bucketName, key);
    }
    // Unconfigured: ask the bucket. Costs a request per descriptor, which is
    // why S3BlobStorageOptions.publicRead exists.
    final isPublic = await _isBucketPublic(bucketName);
    return isPublic
        ? _publicUrl(bucketName, key)
        : _presignedUrl(bucketName, key);
  }

  Future<String?> _presignedUrl(String bucketName, String key) async {
    try {
      return await _presignClient.presignedGetObject(
        bucketName,
        key,
        expires: _presignTtlSeconds,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _publicUrl(String bucketName, String key) async {
    try {
      final client = _presignRawClient ??= minio_internal.MinioClient(
        _presignClient,
      );
      final uri = client.getRequestUrl(bucketName, key, null, null);
      return uri.toString();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _isBucketPublic(String bucketName) async {
    try {
      final policy = await _client.getBucketPolicy(bucketName);
      final statements = policy?['Statement'];
      return statements is Iterable && statements.any(_allowsPublicGetObject);
    } catch (_) {
      return false;
    }
  }

  bool _allowsPublicGetObject(dynamic statement) {
    if (statement is! Map) return false;
    final effect = statement['Effect']?.toString().toLowerCase();
    if (effect != 'allow') return false;
    if (!_isPublicPrincipal(statement['Principal'])) return false;
    return _allowsGetObjectAction(statement['Action']);
  }

  bool _isPublicPrincipal(dynamic principal) {
    if (principal == null) return false;
    if (principal == '*') return true;
    if (principal is String && principal.trim() == '*') return true;
    if (principal is Map) {
      final aws = principal['AWS'] ?? principal['AWS:'];
      if (aws == null) return false;
      if (aws == '*') return true;
      if (aws is Iterable && aws.contains('*')) return true;
      if (aws is String && aws.trim() == '*') return true;
    }
    return false;
  }

  bool _allowsGetObjectAction(dynamic actions) {
    if (actions == null) return false;
    if (actions is String) {
      final action = actions.toLowerCase();
      return action == 's3:getobject' || action == 's3:*' || action == '*';
    }
    if (actions is Iterable) return actions.any(_allowsGetObjectAction);
    return false;
  }

  Future<Map<String, String>> _getObjectTags(
    String bucketName,
    String key,
  ) async {
    try {
      final client = _rawClient ??= minio_internal.MinioClient(_client);
      final response = await client.request(
        method: 'GET',
        bucket: bucketName,
        object: key,
        resource: 'tagging',
      );
      if (response.statusCode != 200) return const <String, String>{};

      final document = xml.XmlDocument.parse(response.body);
      final tags = <String, String>{};
      for (final tag in document.findAllElements('Tag')) {
        final tagKey = tag.getElement('Key')?.value;
        final tagValue = tag.getElement('Value')?.value;
        if (tagKey != null && tagValue != null) tags[tagKey] = tagValue;
      }
      return tags;
    } on MinioError catch (e) {
      if (_isNotFound(e)) return const <String, String>{};
      rethrow;
    } catch (_) {
      return const <String, String>{};
    }
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  /// Normalises a collection name to a valid S3 bucket name segment:
  /// lowercase, only alphanumeric and hyphens, 3–63 chars.
  static String _normalizeBucketName(String collection) {
    var name = collection
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (name.length < 3) name = name.padRight(3, '0');
    if (name.length > 63) name = name.substring(0, 63);
    return name;
  }

  static String _normalizeBucketPrefix(String? prefix) {
    if (prefix == null || prefix.isEmpty) return '';
    var value = prefix.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '-');
    if (!value.endsWith('-')) value = '$value-';
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

  static String _etagLikeChecksum(Uint8List bytes) =>
      md5.convert(bytes).toString();

  static Minio _buildPresignClient(Minio client, S3BlobStorageOptions options) {
    final region = options.presignRegion ?? client.region;
    if (region == null) {
      throw ArgumentError(
        'S3BlobStorageOptions.presignRegion is required to presign URLs '
        'without issuing a region lookup request.',
      );
    }

    final hasOverrides =
        options.presignEndpoint != null ||
        options.presignPort != null ||
        options.presignUseSSL != null ||
        options.presignPathStyle != null;

    if (!hasOverrides) {
      if (client.region != null) return client;
      return Minio(
        endPoint: client.endPoint,
        port: client.port,
        accessKey: client.accessKey,
        secretKey: client.secretKey,
        sessionToken: client.sessionToken,
        useSSL: client.useSSL,
        region: region,
        pathStyle: client.pathStyle,
        enableTrace: client.enableTrace,
      );
    }

    return Minio(
      endPoint: options.presignEndpoint ?? client.endPoint,
      port: options.presignPort ?? client.port,
      accessKey: client.accessKey,
      secretKey: client.secretKey,
      sessionToken: client.sessionToken,
      useSSL: options.presignUseSSL ?? client.useSSL,
      region: region,
      pathStyle: options.presignPathStyle ?? client.pathStyle,
      enableTrace: client.enableTrace,
    );
  }
}
