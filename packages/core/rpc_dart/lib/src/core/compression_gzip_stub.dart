// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:typed_data';

/// Returns false on platforms without dart:io gzip support (e.g. web).
bool get rpcGzipSupported => false;

/// Throws [UnsupportedError] on non-native platforms.
Uint8List rpcGzipCompress(Uint8List data) => throw UnsupportedError(
    'gzip compression is not supported on this platform');

/// Throws [UnsupportedError] on non-native platforms.
Uint8List rpcGzipDecompress(Uint8List data) => throw UnsupportedError(
    'gzip decompression is not supported on this platform');
