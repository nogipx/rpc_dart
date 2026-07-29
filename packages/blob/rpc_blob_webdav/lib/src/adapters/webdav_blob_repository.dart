// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:rpc_blob/rpc_blob.dart';
import 'package:xml/xml.dart' as xml;

import 'webdav_auth.dart';

typedef WebDavClock = DateTime Function();

/// XML namespace for this adapter's dead properties (version/timestamps/meta).
const String _rpcNs = 'urn:rpc-blob';

class WebDavOptions {
  const WebDavOptions({this.trackMetadata = true, this.clock});

  /// Persist per-blob `version` + timestamps + user metadata as WebDAV dead
  /// properties (PROPPATCH), and read them back via PROPFIND. This enables
  /// optimistic concurrency (`expectedVersion`) and metadata round-trips, at
  /// the cost of one extra request per write and a dependency on the server
  /// supporting dead properties (Nextcloud/ownCloud/Apache mod_dav/sabre/dav
  /// do; some minimal servers do not — writes still succeed, but version stays
  /// 1 and metadata is dropped).
  ///
  /// Set `false` for a content-addressed, immutable blob store (no versioning
  /// needed): writes become a single PUT, `version` is always 1, and
  /// `expectedVersion` is ignored.
  final bool trackMetadata;

  /// Clock for timestamps (primarily for tests).
  final WebDavClock? clock;
}

/// A WebDAV-backed [IBlobRepository].
///
/// Each collection maps to a directory under [baseUrl]; each blob id maps to a
/// resource inside it (`<baseUrl>/<collection>/<id>`). The collection directory
/// is created on demand (MKCOL), mirroring the S3 adapter creating a bucket on
/// first write.
///
/// dart2js / VM / Flutter compatible: uses only `package:http` and
/// `package:xml`, never `dart:io`.
class WebDavBlobRepository implements IBlobRepository {
  WebDavBlobRepository({
    required Uri baseUrl,
    WebDavAuth auth = const WebDavAuth.none(),
    http.Client? httpClient,
    WebDavOptions options = const WebDavOptions(),
  }) : _baseUrl = baseUrl,
       _auth = auth,
       _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _trackMetadata = options.trackMetadata,
       _clock = options.clock ?? DateTime.now;

  /// Convenience factory for the common Basic-auth case.
  factory WebDavBlobRepository.connect({
    required String baseUrl,
    String? username,
    String? password,
    String? bearerToken,
    http.Client? httpClient,
    WebDavOptions options = const WebDavOptions(),
  }) {
    final WebDavAuth auth;
    if (bearerToken != null) {
      auth = WebDavAuth.bearer(bearerToken);
    } else if (username != null) {
      auth = WebDavAuth.basic(username: username, password: password ?? '');
    } else {
      auth = const WebDavAuth.none();
    }
    return WebDavBlobRepository(
      baseUrl: Uri.parse(baseUrl),
      auth: auth,
      httpClient: httpClient,
      options: options,
    );
  }

  final Uri _baseUrl;
  final WebDavAuth _auth;
  final http.Client _http;
  final bool _ownsClient;
  final bool _trackMetadata;
  final WebDavClock _clock;

  /// Collections whose directory we've already ensured this session.
  final Set<String> _ensured = {};

  // ---------------------------------------------------------------------------
  // IBlobRepository
  // ---------------------------------------------------------------------------

  @override
  Future<BlobDescriptor?> headBlob(String collection, String id) async {
    final resp = await _send(
      'PROPFIND',
      _objectUri(collection, id),
      headers: {'depth': '0'},
      body: _propfindBody(),
    );
    if (resp.statusCode == 404 || resp.statusCode == 410) return null;
    if (resp.statusCode != 207) {
      throw StateError(
        'WebDAV PROPFIND ${resp.statusCode} for $collection/$id',
      );
    }
    final entries = _parseMultistatus(resp.body);
    final entry = entries.where((e) => !e.isCollection).firstOrNull;
    if (entry == null) return null;
    return _descriptor(collection, id, entry);
  }

  @override
  Future<BlobReadResult?> readBlob(BlobReadRequest request) async {
    final descriptor = await headBlob(request.collection, request.id);
    if (descriptor == null) return null;

    final headers = <String, String>{};
    final start = request.rangeStart;
    final end = request.rangeEnd;
    if (start != null || end != null) {
      final from = start ?? 0;
      if (end != null && end <= from) return null;
      // rpc_blob's rangeEnd is exclusive; the HTTP Range end is inclusive.
      final to = end != null ? '${end - 1}' : '';
      headers['range'] = 'bytes=$from-$to';
    }

    final resp = await _send(
      'GET',
      _objectUri(request.collection, request.id),
      headers: headers,
    );
    if (resp.statusCode == 404 || resp.statusCode == 410) return null;
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw StateError(
        'WebDAV GET ${resp.statusCode} for '
        '${request.collection}/${request.id}',
      );
    }

    return BlobReadResult(
      descriptor: descriptor,
      bytes: Stream.value(resp.bodyBytes),
      rangeStart: start,
      rangeEnd: end,
    );
  }

  @override
  Future<BlobWriteResult> writeBlob(BlobWriteRequest request) async {
    final id = request.id ?? _generateId();
    final bytes = await _collectBytes(request.bytes, request.length);
    if (request.checksum != null) {
      _verifyChecksum(
        bytes,
        request.checksum!,
        algorithm: request.checksumAlgorithm,
      );
    }
    await _ensureCollection(request.collection);

    final now = _clock().toUtc();
    var version = 1;
    var createdAt = now;

    if (_trackMetadata) {
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
      if (existing != null) {
        version = existing.version + 1;
        createdAt = existing.createdAt;
      }
    }

    final putResp = await _send(
      'PUT',
      _objectUri(request.collection, id),
      body: bytes,
      headers: {
        if (request.contentType != null) 'content-type': request.contentType!,
      },
    );
    if (!_isWriteOk(putResp.statusCode)) {
      throw StateError(
        'WebDAV PUT ${putResp.statusCode} for '
        '${request.collection}/$id',
      );
    }

    if (_trackMetadata) {
      await _propPatch(
        request.collection,
        id,
        version: version,
        createdAt: createdAt,
        updatedAt: now,
        metadata: request.metadata,
      );
    }

    return BlobWriteResult(
      descriptor: BlobDescriptor(
        id: id,
        collection: request.collection,
        length: bytes.length,
        version: version,
        createdAt: createdAt,
        updatedAt: now,
        contentType: request.contentType,
        checksum: sha256.convert(bytes).toString(),
        metadata: request.metadata,
        downloadUrl: _objectUri(request.collection, id).toString(),
      ),
    );
  }

  @override
  Future<bool> deleteBlob(
    String collection,
    String id, {
    int? expectedVersion,
  }) async {
    if (_trackMetadata && expectedVersion != null) {
      final existing = await headBlob(collection, id);
      if (existing == null) return false;
      if (existing.version != expectedVersion) {
        throw StateError(
          'Version mismatch for $id: expected $expectedVersion, '
          'actual ${existing.version}.',
        );
      }
    }
    final resp = await _send('DELETE', _objectUri(collection, id));
    if (resp.statusCode == 404 || resp.statusCode == 410) return false;
    if (resp.statusCode == 200 || resp.statusCode == 204) return true;
    throw StateError('WebDAV DELETE ${resp.statusCode} for $collection/$id');
  }

  @override
  Future<void> ensureCollection(String collection) => _ensureCollection(collection);

  @override
  Future<Set<String>> deleteMany(String collection, List<String> ids) async {
    // WebDAV deletes one resource per request; the loop is the batch.
    final removed = <String>{};
    for (final id in ids) {
      if (await deleteBlob(collection, id)) removed.add(id);
    }
    return removed;
  }

  @override
  Future<ListBlobsResponse> listBlobs(ListBlobsRequest request) async {
    final entries = await _propfindChildren(_dirUri(request.collection));
    if (entries == null) return const ListBlobsResponse(items: []);

    final cursor = request.cursor == null || request.cursor!.isEmpty
        ? null
        : utf8.decode(base64Url.decode(request.cursor!));

    final blobs = entries.where((e) => !e.isCollection).toList()
      ..sort((a, b) => _idOf(a).compareTo(_idOf(b)));

    final items = <BlobDescriptor>[];
    String? nextCursor;
    for (final entry in blobs) {
      final id = _idOf(entry);
      if (id.isEmpty) continue;
      if (cursor != null && id.compareTo(cursor) <= 0) continue;
      if (request.prefix != null &&
          request.prefix!.isNotEmpty &&
          !id.startsWith(request.prefix!)) {
        continue;
      }
      items.add(_descriptor(request.collection, id, entry));
      if (items.length == request.limit) {
        nextCursor = base64Url.encode(utf8.encode(id));
        break;
      }
    }
    return ListBlobsResponse(items: items, nextCursor: nextCursor);
  }

  @override
  Future<List<String>> listCollections() async {
    final entries = await _propfindChildren(_rootDirUri());
    if (entries == null) return const [];
    final collections = <String>[];
    for (final entry in entries) {
      if (!entry.isCollection) continue;
      final id = _idOf(entry);
      // Skip the root directory itself (its href has no extra segment).
      if (id.isEmpty || _hrefSegments(entry.href).length <= _baseSegs.length) {
        continue;
      }
      collections.add(id);
    }
    return collections..sort();
  }

  @override
  Future<bool> deleteCollection(String collection) async {
    _ensured.remove(collection);
    final resp = await _send('DELETE', _dirUri(collection));
    if (resp.statusCode == 404 || resp.statusCode == 410) return false;
    if (resp.statusCode == 200 || resp.statusCode == 204) return true;
    throw StateError(
      'WebDAV DELETE ${resp.statusCode} for collection '
      '$collection',
    );
  }

  @override
  Future<int> collectionSize(String collection) async {
    final entries = await _propfindChildren(_dirUri(collection));
    if (entries == null) return 0;
    var total = 0;
    for (final entry in entries) {
      if (entry.isCollection) continue;
      total += entry.length ?? 0;
    }
    return total;
  }

  @override
  Future<void> dispose() async {
    if (_ownsClient) _http.close();
  }

  // ---------------------------------------------------------------------------
  // WebDAV helpers
  // ---------------------------------------------------------------------------

  Future<void> _ensureCollection(String collection) async {
    if (_ensured.contains(collection)) return;
    final resp = await _send('MKCOL', _dirUri(collection));
    // 201 created; 405 already exists / method not allowed on existing;
    // 301 redirect (already there). Anything else: surface unless it's a
    // conflict we can treat as "exists".
    if (resp.statusCode == 201 ||
        resp.statusCode == 405 ||
        resp.statusCode == 301 ||
        resp.statusCode == 200) {
      _ensured.add(collection);
      return;
    }
    if (resp.statusCode == 409) {
      // Parent missing on some servers even though baseUrl should exist —
      // treat as best-effort and let the following PUT surface the real error.
      _ensured.add(collection);
      return;
    }
    throw StateError(
      'WebDAV MKCOL ${resp.statusCode} for collection '
      '$collection',
    );
  }

  Future<void> _propPatch(
    String collection,
    String id, {
    required int version,
    required DateTime createdAt,
    required DateTime updatedAt,
    required Map<String, String> metadata,
  }) async {
    final body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propertyupdate xmlns:D="DAV:" xmlns:R="$_rpcNs">'
        '<D:set><D:prop>'
        '<R:version>$version</R:version>'
        '<R:created>${_xmlEscape(createdAt.toIso8601String())}</R:created>'
        '<R:updated>${_xmlEscape(updatedAt.toIso8601String())}</R:updated>'
        '<R:meta>${_xmlEscape(jsonEncode(metadata))}</R:meta>'
        '</D:prop></D:set>'
        '</D:propertyupdate>';
    try {
      await _send(
        'PROPPATCH',
        _objectUri(collection, id),
        body: utf8.encode(body),
        headers: {'content-type': 'application/xml; charset=utf-8'},
      );
    } catch (_) {
      // Graceful degradation: a server without dead-property support keeps the
      // bytes; version/metadata simply won't round-trip.
    }
  }

  /// PROPFIND Depth:1; returns the child entries (including the directory
  /// itself), or null if the collection does not exist.
  Future<List<_DavEntry>?> _propfindChildren(Uri dirUri) async {
    final resp = await _send(
      'PROPFIND',
      dirUri,
      headers: {'depth': '1'},
      body: _propfindBody(),
    );
    if (resp.statusCode == 404 || resp.statusCode == 410) return null;
    if (resp.statusCode != 207) {
      throw StateError('WebDAV PROPFIND ${resp.statusCode} for $dirUri');
    }
    return _parseMultistatus(resp.body);
  }

  List<int> _propfindBody() {
    const body =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:" xmlns:R="$_rpcNs">'
        '<D:prop>'
        '<D:getcontentlength/>'
        '<D:getcontenttype/>'
        '<D:getlastmodified/>'
        '<D:getetag/>'
        '<D:resourcetype/>'
        '<R:version/>'
        '<R:created/>'
        '<R:updated/>'
        '<R:meta/>'
        '</D:prop>'
        '</D:propfind>';
    return utf8.encode(body);
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    List<int>? body,
    Map<String, String>? headers,
  }) async {
    final request = http.Request(method, uri);
    request.headers.addAll(_auth.headers);
    if (headers != null) request.headers.addAll(headers);
    if (body != null) request.bodyBytes = Uint8List.fromList(body);
    final streamed = await _http.send(request);
    return http.Response.fromStream(streamed);
  }

  // ---------------------------------------------------------------------------
  // URI helpers
  // ---------------------------------------------------------------------------

  List<String> get _baseSegs =>
      _baseUrl.pathSegments.where((s) => s.isNotEmpty).toList();

  Uri _objectUri(String collection, String id) =>
      _baseUrl.replace(pathSegments: [..._baseSegs, collection, id]);

  Uri _dirUri(String collection) =>
      _baseUrl.replace(pathSegments: [..._baseSegs, collection, '']);

  Uri _rootDirUri() => _baseUrl.replace(pathSegments: [..._baseSegs, '']);

  static List<String> _hrefSegments(String href) =>
      Uri.parse(href).pathSegments.where((s) => s.isNotEmpty).toList();

  static String _idOf(_DavEntry entry) {
    final segs = _hrefSegments(entry.href);
    return segs.isEmpty ? '' : segs.last;
  }

  // ---------------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------------

  List<_DavEntry> _parseMultistatus(String body) {
    final doc = xml.XmlDocument.parse(body);
    final entries = <_DavEntry>[];
    for (final response in doc.findAllElements('response', namespace: '*')) {
      final href = response
          .getElement('href', namespace: '*')
          ?.innerText
          .trim();
      if (href == null || href.isEmpty) continue;

      // Prefer the propstat carrying HTTP 200; fall back to the first prop.
      xml.XmlElement? prop;
      for (final propstat in response.findElements(
        'propstat',
        namespace: '*',
      )) {
        final status =
            propstat.getElement('status', namespace: '*')?.innerText ?? '';
        if (status.contains(' 200')) {
          prop = propstat.getElement('prop', namespace: '*');
          break;
        }
      }
      prop ??= response
          .findElements('propstat', namespace: '*')
          .firstOrNull
          ?.getElement('prop', namespace: '*');
      if (prop == null) continue;

      final resourcetype = prop.getElement('resourcetype', namespace: '*');
      final isCollection =
          resourcetype != null &&
          resourcetype.childElements.any((e) => e.name.local == 'collection');

      final lengthText = prop
          .getElement('getcontentlength', namespace: '*')
          ?.innerText;
      final contentType = prop
          .getElement('getcontenttype', namespace: '*')
          ?.innerText
          .trim();
      final lastModifiedText = prop
          .getElement('getlastmodified', namespace: '*')
          ?.innerText
          .trim();
      final etag = prop.getElement('getetag', namespace: '*')?.innerText.trim();

      final versionText = prop
          .getElement('version', namespace: _rpcNs)
          ?.innerText
          .trim();
      final createdText = prop
          .getElement('created', namespace: _rpcNs)
          ?.innerText
          .trim();
      final updatedText = prop
          .getElement('updated', namespace: _rpcNs)
          ?.innerText
          .trim();
      final metaText = prop
          .getElement('meta', namespace: _rpcNs)
          ?.innerText
          .trim();

      entries.add(
        _DavEntry(
          href: href,
          isCollection: isCollection,
          length: lengthText != null ? int.tryParse(lengthText.trim()) : null,
          contentType: (contentType == null || contentType.isEmpty)
              ? null
              : contentType,
          lastModified: lastModifiedText != null
              ? _parseRfc1123(lastModifiedText)
              : null,
          etag: (etag == null || etag.isEmpty) ? null : _unquote(etag),
          version: versionText != null ? int.tryParse(versionText) : null,
          created: _tryParseIso(createdText),
          updated: _tryParseIso(updatedText),
          metadata: _tryParseMeta(metaText),
        ),
      );
    }
    return entries;
  }

  BlobDescriptor _descriptor(String collection, String id, _DavEntry entry) {
    final updated = entry.updated ?? entry.lastModified ?? _clock().toUtc();
    final created = entry.created ?? entry.lastModified ?? updated;
    return BlobDescriptor(
      id: id,
      collection: collection,
      length: entry.length ?? 0,
      version: entry.version ?? 1,
      createdAt: created,
      updatedAt: updated,
      contentType: entry.contentType,
      checksum: entry.etag,
      metadata: entry.metadata,
      downloadUrl: _objectUri(collection, id).toString(),
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  static bool _isWriteOk(int code) => code == 200 || code == 201 || code == 204;

  static Future<Uint8List> _collectBytes(
    Stream<Uint8List> stream,
    int? declaredLength,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (declaredLength != null && declaredLength != bytes.length) {
      throw StateError(
        'Length mismatch: declared=$declaredLength actual=${bytes.length} bytes',
      );
    }
    return bytes;
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

  static String _unquote(String s) {
    var out = s;
    if (out.startsWith('W/')) out = out.substring(2);
    if (out.length >= 2 && out.startsWith('"') && out.endsWith('"')) {
      out = out.substring(1, out.length - 1);
    }
    return out;
  }

  static DateTime? _tryParseIso(String? s) {
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toUtc();
  }

  static Map<String, String> _tryParseMeta(String? s) {
    if (s == null || s.isEmpty) return const {};
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
    return const {};
  }

  static const Map<String, int> _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  /// Parse an RFC 1123 HTTP date (`Wed, 15 Jul 2026 12:00:00 GMT`) without
  /// `dart:io`'s HttpDate (which is unavailable on dart2js).
  static DateTime? _parseRfc1123(String s) {
    try {
      final parts = s.trim().split(RegExp(r'\s+'));
      if (parts.length < 5) return null;
      final day = int.parse(parts[1]);
      final month = _months[parts[2].toLowerCase()];
      if (month == null) return null;
      final year = int.parse(parts[3]);
      final time = parts[4].split(':');
      return DateTime.utc(
        year,
        month,
        day,
        int.parse(time[0]),
        int.parse(time[1]),
        int.parse(time[2]),
      );
    } catch (_) {
      return null;
    }
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _generateId() {
    const alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List<int>.generate(
        16,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }
}

class _DavEntry {
  _DavEntry({
    required this.href,
    required this.isCollection,
    this.length,
    this.contentType,
    this.lastModified,
    this.etag,
    this.version,
    this.created,
    this.updated,
    this.metadata = const {},
  });

  final String href;
  final bool isCollection;
  final int? length;
  final String? contentType;
  final DateTime? lastModified;
  final String? etag;
  final int? version;
  final DateTime? created;
  final DateTime? updated;
  final Map<String, String> metadata;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
