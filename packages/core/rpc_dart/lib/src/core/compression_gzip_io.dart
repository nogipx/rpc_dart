// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io' show gzip;
import 'dart:typed_data';

/// Returns true on native platforms where dart:io gzip is available.
bool get rpcGzipSupported => true;

/// Compresses [data] using dart:io gzip.
Uint8List rpcGzipCompress(Uint8List data) =>
    Uint8List.fromList(gzip.encode(data));

/// Decompresses [data] using dart:io gzip.
Uint8List rpcGzipDecompress(Uint8List data) =>
    Uint8List.fromList(gzip.decode(data));
