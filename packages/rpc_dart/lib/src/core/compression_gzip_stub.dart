// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

bool get rpcGzipSupported => false;

Uint8List rpcGzipCompress(Uint8List data) => throw UnsupportedError(
    'gzip compression is not supported on this platform');

Uint8List rpcGzipDecompress(Uint8List data) => throw UnsupportedError(
    'gzip decompression is not supported on this platform');
