// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rpc_blob_webdav/rpc_blob_webdav.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart' as xml;

final Uri _base = Uri.parse('http://dav.test/dav');

Stream<Uint8List> _bytes(List<int> b) => Stream.value(Uint8List.fromList(b));

void main() {
  late _FakeWebDav dav;

  WebDavBlobRepository repo({bool trackMetadata = true, WebDavAuth? auth}) =>
      WebDavBlobRepository(
        baseUrl: _base,
        auth: auth ?? WebDavAuth.basic(username: 'u', password: 'p'),
        httpClient: dav.client,
        options: WebDavOptions(trackMetadata: trackMetadata),
      );

  setUp(() => dav = _FakeWebDav(seedDirs: const ['dav']));

  test('write -> head -> read round-trips', () async {
    final r = repo();
    final data = utf8.encode('hello webdav');
    final put = await r.writeBlob(
      BlobWriteRequest(
        collection: 'notes',
        id: 'a',
        bytes: _bytes(data),
        length: data.length,
        contentType: 'text/plain',
      ),
    );
    expect(put.descriptor.length, data.length);
    expect(put.descriptor.version, 1);

    final head = await r.headBlob('notes', 'a');
    expect(head, isNotNull);
    expect(head!.length, data.length);
    expect(head.contentType, 'text/plain');

    final read = await r.readBlob(
      BlobReadRequest(collection: 'notes', id: 'a'),
    );
    expect(read, isNotNull);
    expect(await read!.bytes.collectBytes(), equals(data));
  });

  test('ranged read returns the exclusive-end slice', () async {
    final r = repo();
    final data = utf8.encode('0123456789');
    await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'x',
        bytes: _bytes(data),
        length: data.length,
      ),
    );

    final read = await r.readBlob(
      BlobReadRequest(collection: 'c', id: 'x', rangeStart: 2, rangeEnd: 5),
    );
    expect(await read!.bytes.collectBytes(), equals(utf8.encode('234')));
  });

  test('missing blob reads null', () async {
    final r = repo();
    expect(await r.headBlob('c', 'nope'), isNull);
    expect(
      await r.readBlob(BlobReadRequest(collection: 'c', id: 'nope')),
      isNull,
    );
  });

  test('version increments; expectedVersion mismatch throws', () async {
    final r = repo();
    final v1 = await r.writeBlob(
      BlobWriteRequest(collection: 'c', id: 'x', bytes: _bytes([1])),
    );
    expect(v1.descriptor.version, 1);

    final v2 = await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'x',
        bytes: _bytes([2]),
        expectedVersion: 1,
      ),
    );
    expect(v2.descriptor.version, 2);

    expect(
      () => r.writeBlob(
        BlobWriteRequest(
          collection: 'c',
          id: 'x',
          bytes: _bytes([3]),
          expectedVersion: 1,
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('metadata + content-type round-trip via dead properties', () async {
    final r = repo();
    await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'x',
        bytes: _bytes([1, 2, 3]),
        contentType: 'application/octet-stream',
        metadata: const {'author': 'nogi', 'kind': 'chunk'},
      ),
    );
    final head = await r.headBlob('c', 'x');
    expect(head!.contentType, 'application/octet-stream');
    expect(head.metadata['author'], 'nogi');
    expect(head.metadata['kind'], 'chunk');
  });

  test('listBlobs: prefix filter + cursor pagination', () async {
    final r = repo();
    for (final id in ['a1', 'a2', 'a3', 'b1']) {
      await r.writeBlob(
        BlobWriteRequest(collection: 'c', id: id, bytes: _bytes([0])),
      );
    }

    final all = await r.listBlobs(const ListBlobsRequest(collection: 'c'));
    expect(all.items.map((e) => e.id).toSet(), {'a1', 'a2', 'a3', 'b1'});

    final onlyA = await r.listBlobs(
      const ListBlobsRequest(collection: 'c', prefix: 'a'),
    );
    expect(onlyA.items.map((e) => e.id).toList(), ['a1', 'a2', 'a3']);

    final page1 = await r.listBlobs(
      const ListBlobsRequest(collection: 'c', limit: 2),
    );
    expect(page1.items.map((e) => e.id).toList(), ['a1', 'a2']);
    expect(page1.nextCursor, isNotNull);
    final page2 = await r.listBlobs(
      ListBlobsRequest(collection: 'c', limit: 2, cursor: page1.nextCursor),
    );
    expect(page2.items.map((e) => e.id).toList(), ['a3', 'b1']);
  });

  test('listCollections returns directories under the root', () async {
    final r = repo();
    await r.writeBlob(
      BlobWriteRequest(collection: 'alpha', id: 'x', bytes: _bytes([1])),
    );
    await r.writeBlob(
      BlobWriteRequest(collection: 'beta', id: 'y', bytes: _bytes([1])),
    );
    expect((await r.listCollections()).toSet(), {'alpha', 'beta'});
  });

  test('collectionSize sums blob lengths', () async {
    final r = repo();
    await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'x',
        bytes: _bytes(List.filled(10, 0)),
      ),
    );
    await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'y',
        bytes: _bytes(List.filled(5, 0)),
      ),
    );
    expect(await r.collectionSize('c'), 15);
    expect(await r.collectionSize('empty'), 0);
  });

  test('deleteBlob and deleteCollection', () async {
    final r = repo();
    await r.writeBlob(
      BlobWriteRequest(collection: 'c', id: 'x', bytes: _bytes([1])),
    );
    expect(await r.deleteBlob('c', 'x'), isTrue);
    expect(await r.deleteBlob('c', 'x'), isFalse); // already gone
    expect(await r.headBlob('c', 'x'), isNull);

    await r.writeBlob(
      BlobWriteRequest(collection: 'c', id: 'y', bytes: _bytes([1])),
    );
    expect(await r.deleteCollection('c'), isTrue);
    expect(await r.deleteCollection('c'), isFalse);
  });

  test('checksum verification: correct passes, wrong throws', () async {
    final r = repo();
    final data = utf8.encode('verify me');
    final sum = sha256Hex(data);
    await r.writeBlob(
      BlobWriteRequest(
        collection: 'c',
        id: 'ok',
        bytes: _bytes(data),
        checksum: sum,
      ),
    );
    expect(
      () => r.writeBlob(
        BlobWriteRequest(
          collection: 'c',
          id: 'bad',
          bytes: _bytes(data),
          checksum: 'deadbeef',
        ),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('auth header is attached to every request', () async {
    final r = repo(
      auth: WebDavAuth.basic(username: 'alice', password: 'secret'),
    );
    await r.writeBlob(
      BlobWriteRequest(collection: 'c', id: 'x', bytes: _bytes([1])),
    );
    final expected = 'Basic ${base64.encode(utf8.encode('alice:secret'))}';
    expect(dav.lastAuthorization, expected);
  });

  test(
    'trackMetadata=false: single PUT, no PROPPATCH, version stays 1',
    () async {
      final r = repo(trackMetadata: false);
      await r.writeBlob(
        BlobWriteRequest(collection: 'c', id: 'x', bytes: _bytes([1])),
      );
      await r.writeBlob(
        BlobWriteRequest(collection: 'c', id: 'x', bytes: _bytes([2, 2])),
      );
      expect(dav.propPatchCount, 0);
      final head = await r.headBlob('c', 'x');
      expect(head!.version, 1);
      expect(head.length, 2);
    },
  );
}

// ---------------------------------------------------------------------------
// A minimal, stateful in-process WebDAV server behind a MockClient.
// ---------------------------------------------------------------------------

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

class _Node {
  _Node.dir() : isDir = true, bytes = null;
  _Node.object(this.bytes) : isDir = false;

  final bool isDir;
  Uint8List? bytes;
  String? contentType;
  final Map<String, String> props = {};
}

class _FakeWebDav {
  _FakeWebDav({List<String> seedDirs = const []}) {
    for (final d in seedDirs) {
      _nodes[d] = _Node.dir();
    }
  }

  final Map<String, _Node> _nodes = {};
  String? lastAuthorization;
  int propPatchCount = 0;

  http.Client get client => MockClient(_handle);

  String _key(Uri u) => u.pathSegments.where((s) => s.isNotEmpty).join('/');

  Future<http.Response> _handle(http.Request req) async {
    lastAuthorization = req.headers['authorization'];
    final key = _key(req.url);
    switch (req.method) {
      case 'MKCOL':
        if (_nodes.containsKey(key)) return http.Response('', 405);
        _nodes[key] = _Node.dir();
        return http.Response('', 201);

      case 'PUT':
        final existed = _nodes[key];
        final node = _Node.object(Uint8List.fromList(req.bodyBytes));
        node.contentType = req.headers['content-type'];
        if (existed != null && !existed.isDir) node.props.addAll(existed.props);
        _nodes[key] = node;
        return http.Response('', existed == null ? 201 : 204);

      case 'GET':
        final node = _nodes[key];
        if (node == null || node.isDir) return http.Response('', 404);
        final range = req.headers['range'];
        if (range != null) {
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
          if (m != null) {
            final from = int.parse(m.group(1)!);
            final to = m.group(2)!.isEmpty
                ? node.bytes!.length - 1
                : int.parse(m.group(2)!);
            final slice = node.bytes!.sublist(from, to + 1);
            return http.Response.bytes(slice, 206);
          }
        }
        return http.Response.bytes(node.bytes!, 200);

      case 'DELETE':
        final node = _nodes.remove(key);
        if (node == null) return http.Response('', 404);
        if (node.isDir) {
          _nodes.removeWhere((k, _) => k.startsWith('$key/'));
        }
        return http.Response('', 204);

      case 'PROPPATCH':
        final node = _nodes[key];
        if (node == null) return http.Response('', 404);
        propPatchCount++;
        final doc = xml.XmlDocument.parse(utf8.decode(req.bodyBytes));
        for (final name in ['version', 'created', 'updated', 'meta']) {
          final el = doc.findAllElements(name, namespace: '*').firstOrNull;
          if (el != null) node.props[name] = el.innerText;
        }
        return http.Response(_multistatus([_responseXml('/$key', node)]), 207);

      case 'PROPFIND':
        final node = _nodes[key];
        if (node == null) return http.Response('', 404);
        final depth = req.headers['depth'] ?? '0';
        final responses = <String>[_responseXml(_href(key, node), node)];
        if (depth == '1' && node.isDir) {
          final childKeys =
              _nodes.keys.where((k) => k != key && _parent(k) == key).toList()
                ..sort();
          for (final ck in childKeys) {
            responses.add(_responseXml(_href(ck, _nodes[ck]!), _nodes[ck]!));
          }
        }
        return http.Response(_multistatus(responses), 207);
    }
    return http.Response('', 405);
  }

  static String _parent(String key) {
    final i = key.lastIndexOf('/');
    return i < 0 ? '' : key.substring(0, i);
  }

  String _href(String key, _Node node) => node.isDir ? '/$key/' : '/$key';

  String _multistatus(List<String> responses) =>
      '<?xml version="1.0" encoding="utf-8"?>'
      '<D:multistatus xmlns:D="DAV:" xmlns:R="urn:rpc-blob">'
      '${responses.join()}'
      '</D:multistatus>';

  String _responseXml(String href, _Node node) {
    final props = StringBuffer();
    if (node.isDir) {
      props.write('<D:resourcetype><D:collection/></D:resourcetype>');
    } else {
      props.write('<D:resourcetype/>');
      props.write(
        '<D:getcontentlength>${node.bytes!.length}'
        '</D:getcontentlength>',
      );
      if (node.contentType != null) {
        props.write(
          '<D:getcontenttype>${_esc(node.contentType!)}'
          '</D:getcontenttype>',
        );
      }
      props.write(
        '<D:getlastmodified>Wed, 15 Jul 2026 12:00:00 GMT'
        '</D:getlastmodified>',
      );
      props.write('<D:getetag>"etag-${node.bytes!.length}"</D:getetag>');
      node.props.forEach((k, v) {
        props.write('<R:$k>${_esc(v)}</R:$k>');
      });
    }
    return '<D:response>'
        '<D:href>${_esc(href)}</D:href>'
        '<D:propstat><D:prop>$props</D:prop>'
        '<D:status>HTTP/1.1 200 OK</D:status></D:propstat>'
        '</D:response>';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
