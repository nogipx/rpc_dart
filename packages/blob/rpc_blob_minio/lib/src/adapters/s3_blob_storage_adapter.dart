// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The minio package keeps its raw client out of its public library, and the
// tagging/presign paths need it.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:minio/minio.dart';
// Prefixed, always: this library exports a class named `Object`, and importing
// it plainly shadows dart:core's in every signature in this file.
import 'package:minio/models.dart' as minio;
import 'package:minio/src/minio_client.dart' as minio_internal;
import 'package:rpc_blob/rpc_blob.dart';
import 'package:xml/xml.dart' as xml;

typedef S3Clock = DateTime Function();

const int kDefaultPresignTtlSeconds = 3600;

class S3BlobStorageOptions {
  const S3BlobStorageOptions({
    this.bucket = 'blobs',
    this.maxRetries = 3,
    this.retryBaseDelay = const Duration(milliseconds: 200),
    this.requestTimeout,
    this.fetchObjectTags = false,
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

  /// The single bucket every collection lives in, as a key prefix.
  final String bucket;

  /// How many times a request is retried after a throttling or transient
  /// failure. 0 disables retrying.
  ///
  /// A hosted S3 answers `503 SlowDown` when a prefix is being written to
  /// harder than it has scaled for, and expects the client to back off. A
  /// local MinIO effectively never does, which is why this was easy to not
  /// notice until it mattered.
  final int maxRetries;

  /// First backoff step. Each attempt doubles it, with jitter so a fleet
  /// backing off together does not resynchronise into the same burst.
  final Duration retryBaseDelay;

  /// Ceiling on a single request.
  ///
  /// Applies to the call, not to draining a download stream: a large but
  /// healthy transfer is not a stuck one. Null leaves it to the socket, which
  /// can mean waiting on a dead connection for a very long time.
  final Duration? requestTimeout;

  /// Read S3 object tags when building a descriptor, merging them into
  /// `metadata`.
  ///
  /// Off by default because this adapter never writes tags: paying a
  /// `GET ?tagging` on every head for something only an outside tool could
  /// have set is a poor trade. Turn it on if something else tags these
  /// objects and you need to see it.
  final bool fetchObjectTags;

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
/// Every collection lives in ONE bucket as a key prefix: an object is stored
/// at `<collection>/<id>`.
///
/// A bucket per collection does not survive a move to a hosted S3 — providers
/// cap how many buckets an account may have, and creating one is a heavyweight
/// operation with its own rate limits. Prefixes have neither limit, and cost
/// nothing to "create".
///
/// The trade is that a collection is no longer a thing the store knows about:
/// [collectionSize] cannot be answered cheaply (it returns null) and
/// [deleteCollection] is a prefix walk rather than a bucket drop.
class S3BlobRepository implements IBlobRepository {
  S3BlobRepository({
    required Minio client,
    S3BlobStorageOptions options = const S3BlobStorageOptions(),
  }) : _client = client,
       _presignClient = _buildPresignClient(client, options),
       _bucket = options.bucket,
       _maxRetries = options.maxRetries,
       _retryBaseDelay = options.retryBaseDelay,
       _requestTimeout = options.requestTimeout,
       _fetchObjectTags = options.fetchObjectTags,
       _immutableObjects = options.immutableObjects,
       _createCollectionOnWrite = options.createCollectionOnWrite,
       _publicRead = options.publicRead,
       _clock = options.clock ?? DateTime.now,
       _presignTtlSeconds =
           options.presignTtlSeconds ?? kDefaultPresignTtlSeconds {
    assert(_presignTtlSeconds > 0, 'presignTtlSeconds must be positive');
  }

  /// Convenience factory to create a MinIO/S3 client.
  ///
  /// [pathStyle] false is virtual-host addressing, which hosted S3 expects;
  /// MinIO usually wants it true. Give [region] for a hosted bucket: without
  /// it the client looks the region up on first use, which is a request that
  /// can also fail on a locked-down credential.
  factory S3BlobRepository.connect({
    String endPoint = 'localhost',
    int? port,
    required String accessKey,
    required String secretKey,
    String? sessionToken,
    bool useSSL = true,
    bool pathStyle = false,
    String? region,
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
      region: region,
    );
    return S3BlobRepository(client: client, options: options);
  }

  final Minio _client;
  final Minio _presignClient;
  final String _bucket;
  final int _maxRetries;
  final Duration _retryBaseDelay;
  final Duration? _requestTimeout;
  final bool _fetchObjectTags;
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

  static final _random = Random();

  /// Runs one S3 request, retrying what is worth retrying.
  ///
  /// Only discrete calls go through here. Listings are streams whose paging
  /// state lives inside the client, so restarting one mid-flight would replay
  /// objects rather than resume; a caller that needs a listing to survive a
  /// blip re-runs the listing.
  ///
  /// Every operation this wraps is idempotent — reads, deletes, and writes of
  /// content-addressed objects — so a retry after an ambiguous failure cannot
  /// produce a second effect.
  Future<T> _request<T>(Future<T> Function() send) async {
    var attempt = 0;
    while (true) {
      try {
        final pending = send();
        final timeout = _requestTimeout;
        return timeout == null ? await pending : await pending.timeout(timeout);
      } catch (error) {
        attempt++;
        if (attempt > _maxRetries || !_isRetryable(error)) rethrow;
        await Future<void>.delayed(_backoffFor(attempt));
      }
    }
  }

  /// Exponential with jitter, capped at 16x the base step. The jitter matters
  /// more than the curve: without it every client that failed together retries
  /// together.
  Duration _backoffFor(int attempt) {
    final factor = attempt >= 5 ? 16 : 1 << (attempt - 1);
    final base = _retryBaseDelay.inMicroseconds * factor;
    final jitter = (base * 0.25 * _random.nextDouble()).round();
    return Duration(microseconds: base + jitter);
  }

  /// Throttling and transient server faults are worth another attempt; a
  /// missing key or a bad signature is not, and retrying those just turns one
  /// error into four.
  static bool _isRetryable(Object error) {
    if (error is TimeoutException) return true;
    if (error is MinioS3Error) {
      final status = error.response?.statusCode;
      if (status != null &&
          (status == 429 || (status >= 500 && status <= 599))) {
        return true;
      }
      final code = error.error?.code?.toLowerCase();
      if (code != null &&
          const {
            'slowdown',
            'requesttimeout',
            'internalerror',
            'serviceunavailable',
            'throttling',
            'throttlingexception',
            'requestthrottled',
            'requestthrottledexception',
            'requesttimetooskewed',
          }.contains(code)) {
        return true;
      }
      return false;
    }
    // Anything that is not an S3 answer at all — a dropped socket, a DNS
    // hiccup, a TLS reset — reached us as a raw transport error, and those are
    // the failures a retry exists for.
    return error is! MinioError;
  }

  @override
  Future<void> ensureCollection(String collection) async {
    // A prefix is not a thing that exists — ensuring a collection means
    // ensuring the one bucket everything lives in.
    _prefixFor(collection); // validates the name
    await _ensureBucket(_bucket);
  }

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    final key = _keyFor(collection, id);
    try {
      final stat = await _request(() => _client.statObject(_bucket, key));
      final tags = _fetchObjectTags
          ? await _getObjectTags(_bucket, key)
          : const <String, String>{};
      final url = await _downloadUrl(_bucket, key);
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
  Future<Map<String, BlobDescriptor>> headMany(
    String collection,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    // S3 has no batch metadata call, so this stays one request per id — but
    // in flights of [_headConcurrency] rather than strictly one after another,
    // which is what made a batch of N cost N round trips end to end.
    final found = <String, BlobDescriptor>{};
    for (var i = 0; i < ids.length; i += _headConcurrency) {
      final end = i + _headConcurrency;
      final chunk = ids.sublist(i, end < ids.length ? end : ids.length);
      final descriptors = await Future.wait(
        chunk.map((id) => headBlob(collection, id)),
      );
      for (var j = 0; j < chunk.length; j++) {
        final descriptor = descriptors[j];
        if (descriptor != null) found[chunk[j]] = descriptor;
      }
    }
    return found;
  }

  /// In-flight HEADs per batch. High enough to hide the round trip, low enough
  /// not to look like a burst to a provider that rate-limits.
  static const _headConcurrency = 16;

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async {
    final key = _keyFor(request.collection, request.id);
    final stat = await headBlob(request.collection, request.id);
    if (stat == null) return null;

    final offset = request.rangeStart ?? 0;
    int? length;
    if (request.rangeEnd != null) {
      if (request.rangeEnd! <= offset) return null;
      length = request.rangeEnd! - offset;
    }

    // The call is retried, not the draining of the stream it returns: a slow
    // but healthy transfer is not a failure, and restarting mid-body would
    // hand the caller overlapping bytes.
    final stream = await _request(
      () => _client.getPartialObject(_bucket, key, offset, length),
    );

    return BlobReadResult(
      descriptor: stat,
      bytes: stream.map((chunk) => Uint8List.fromList(chunk)),
      rangeStart: request.rangeStart,
      rangeEnd: request.rangeEnd,
    );
  }

  /// Buffers the whole object in memory before sending it.
  ///
  /// The interface asks implementations to stream, and this one does not: the
  /// checksum is verified over the bytes actually stored, and a retry has to
  /// be able to send them again. The ceiling that follows is
  /// `memory / concurrent writes`, which suits the megabyte-scale chunks this
  /// is used for and rules out very large single objects — those want
  /// multipart, which this adapter does not do yet.
  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) async {
    final id = request.id ?? _generateId();
    final key = _keyFor(request.collection, id);

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

    await _putObject(_bucket, key, collected, metadata);

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
        downloadUrl: await _downloadUrl(_bucket, key),
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
    // Re-sending needs the bytes again, which is exactly why writeBlob buffers
    // them: a retry rebuilds the stream from the same buffer.
    Future<void> put() => _request(
          () => _client.putObject(
            bucketName,
            id,
            Stream.value(bytes),
            size: bytes.length,
            metadata: metadata,
          ),
        );
    try {
      await put();
    } on MinioError catch (e) {
      if (!_createCollectionOnWrite || !_isNoSuchBucket(e)) rethrow;
      await _ensureBucket(bucketName);
      await put();
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
    await _request(() => _client.removeObject(_bucket, _keyFor(collection, id)));
    return true;
  }

  @override
  Future<Set<String>> deleteMany(String collection, List<String> ids) async {
    if (ids.isEmpty) return const {};
    if (!await _bucketExists(_bucket)) return const {};
    final keys = [for (final id in ids) _keyFor(collection, id)];
    // DeleteObjects takes up to 1000 keys per request; without this a reclaim
    // of N chunks was N round trips, and in a cloud S3 N billed requests.
    for (var i = 0; i < keys.length; i += _deleteBatchSize) {
      final end = i + _deleteBatchSize;
      final batch = keys.sublist(i, end < keys.length ? end : keys.length);
      await _request(() => _client.removeObjects(_bucket, batch));
    }
    // S3 reports no per-key existence for a batch delete, so the honest answer
    // is "all of them are gone now" rather than a subset we cannot determine.
    return ids.toSet();
  }

  /// S3's documented ceiling for one DeleteObjects request.
  static const _deleteBatchSize = 1000;

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    if (!await _bucketExists(_bucket)) {
      return const ListBlobsResponse(items: []);
    }

    final cursor = request.cursor == null || request.cursor!.isEmpty
        ? null
        : utf8.decode(base64Url.decode(request.cursor!));
    final items = <BlobDescriptor>[];
    String? nextCursor;

    // The collection's prefix goes to S3, so the server skips other
    // collections instead of this loop filtering them out.
    final prefix = _prefixFor(request.collection) + (request.prefix ?? '');

    await for (final chunk in _client.listObjects(
      _bucket,
      prefix: prefix,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final key = object.key ?? '';
        final id = key.isEmpty ? null : _idFromKey(request.collection, key);
        if (id == null) continue;
        if (cursor != null && id.compareTo(cursor) <= 0) continue;

        // The listing already carries size and mtime. Only a caller that asked
        // for metadata pays a HEAD per object — everything else was turning a
        // page of N into N+1 requests, which on a cloud S3 is N+1 billed ones.
        final BlobDescriptor? descriptor;
        if (request.includeMetadata) {
          descriptor = await headBlob(request.collection, id);
        } else {
          descriptor = _descriptorFromListing(request.collection, id, object);
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
    if (!await _bucketExists(_bucket)) return const [];
    // Non-recursive listing returns the common prefixes, which is exactly the
    // set of collections — no per-object walk.
    final collections = <String>{};
    await for (final chunk in _client.listObjects(_bucket, recursive: false)) {
      for (final prefix in chunk.prefixes) {
        final name = prefix.endsWith('/')
            ? prefix.substring(0, prefix.length - 1)
            : prefix;
        if (name.isNotEmpty) collections.add(name);
      }
    }
    return collections.toList()..sort();
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    if (!await _bucketExists(_bucket)) return false;
    // The bucket is shared now, so dropping a collection means deleting its
    // keys — in batches, not one request per object.
    final prefix = _prefixFor(collection);
    var removed = false;
    var batch = <String>[];
    Future<void> flush() async {
      if (batch.isEmpty) return;
      for (var i = 0; i < batch.length; i += _deleteBatchSize) {
        final end = i + _deleteBatchSize;
        final slice = batch.sublist(i, end < batch.length ? end : batch.length);
        await _request(() => _client.removeObjects(_bucket, slice));
      }
      removed = true;
      batch = <String>[];
    }

    await for (final chunk in _client.listObjects(
      _bucket,
      prefix: prefix,
      recursive: true,
    )) {
      for (final object in chunk.objects) {
        final key = object.key;
        if (key == null || !key.startsWith(prefix)) continue;
        batch.add(key);
        if (batch.length >= _deleteBatchSize) await flush();
      }
    }
    await flush();
    return removed;
  }

  @override
  Future<int?> collectionSize(String collection) async {
    // Null, not a number: a collection is a key prefix here, and S3 offers no
    // way to size one without enumerating it. The MinIO admin API that used to
    // answer this reports per BUCKET, which no longer corresponds to anything.
    //
    // A caller that needs the number sums [listBlobs] and pays for it in the
    // open. One that needs it often should keep its own count.
    _prefixFor(collection); // validates the name
    return null;
  }


  @override
  Future<void> dispose() async {
    // Minio client has no explicit close.
  }

  // ---------------------------------------------------------------------------
  // Bucket helpers
  // ---------------------------------------------------------------------------

  /// Key under which a blob lives: `<collection>/<id>`.
  String _keyFor(String collection, String id) =>
      '${_prefixFor(collection)}$id';

  /// Key prefix owned by a collection. The separator is what makes the reverse
  /// mapping unambiguous, so a collection may not contain one itself.
  String _prefixFor(String collection) {
    if (collection.contains('/')) {
      throw ArgumentError.value(
        collection,
        'collection',
        'must not contain "/" — it separates the collection from the blob id',
      );
    }
    return '$collection/';
  }

  /// Blob id from a full key, or null when the key is not this collection's.
  String? _idFromKey(String collection, String key) {
    final prefix = _prefixFor(collection);
    if (!key.startsWith(prefix)) return null;
    final id = key.substring(prefix.length);
    return id.isEmpty ? null : id;
  }

  /// Ensures the bucket exists, creating it if necessary.
  ///
  /// `bucketExists` then `makeBucket` is check-then-act: concurrent uploads to a
  /// new bucket (e.g. parallel startup uploads) all see it missing and all call
  /// `makeBucket`; the losers get BucketAlreadyOwnedByYou / BucketAlreadyExists.
  /// That means the bucket is there — treat it as idempotent success.
  Future<void> _ensureBucket(String bucketName) async {
    if (await _request(() => _client.bucketExists(bucketName))) return;
    try {
      await _request(() => _client.makeBucket(bucketName));
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
      _request(() => _client.bucketExists(bucketName));

  // ---------------------------------------------------------------------------
  // Descriptor / metadata helpers
  // ---------------------------------------------------------------------------

  /// Builds a descriptor from a list entry, without a HEAD.
  ///
  /// Carries what S3 returns for a listing — size, mtime, ETag. `contentType`,
  /// user metadata and the stored version live in object metadata and stay
  /// absent here; a caller that needs them sets
  /// [ListBlobsRequest.includeMetadata], which is what that flag is for.
  BlobDescriptor _descriptorFromListing(
    String collection,
    String id,
    minio.Object object,
  ) {
    final lastModified = (object.lastModified ?? _clock()).toUtc();
    return BlobDescriptor(
      id: id,
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
    minio.StatObjectResult stat, {
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
