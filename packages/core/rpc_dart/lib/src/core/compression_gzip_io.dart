// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io' show gzip;
import 'dart:typed_data';

bool get rpcGzipSupported => true;

Uint8List rpcGzipCompress(Uint8List data) =>
    Uint8List.fromList(gzip.encode(data));

Uint8List rpcGzipDecompress(Uint8List data) =>
    Uint8List.fromList(gzip.decode(data));
