// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

@TestOn('js')
library;

import 'package:rpc_blob_webdav/rpc_blob_webdav.dart';
import 'package:test/test.dart';

/// Compile-only web smoke test for the dart2js surface.
///
/// Referencing these symbols forces the compiler to resolve the full web
/// import chain. If any web-reachable file imported `dart:io`, this test would
/// fail to compile to JS — which is the whole point of this package existing
/// separately from `rpc_blob_minio` (whose `minio` dependency pulls `dart:io`).
void main() {
  test('web-facing types compile to JS', () {
    final repo = WebDavBlobRepository(
      baseUrl: Uri.parse('https://dav.example.com/blobs'),
      auth: WebDavAuth.basic(username: 'u', password: 'p'),
    );
    expect(repo, isA<IBlobRepository>());
    expect(const WebDavAuth.none().headers, isEmpty);
    expect(WebDavAuth.bearer('t').headers['authorization'], 'Bearer t');
    expect(const WebDavOptions().trackMetadata, isTrue);
  });
}
