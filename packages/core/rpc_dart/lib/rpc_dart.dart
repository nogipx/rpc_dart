// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

library;

export 'dart:typed_data';

export 'logger.dart';

// The public surface cannot be narrowed here yet. `lib/src/endpoint/_index.dart`
// imports `package:rpc_dart/rpc_dart.dart` — core's own implementation depends
// on core's public barrel — so a `hide` on this line breaks the library itself,
// not only its consumers. Measured: 78 analyzer errors, 7 of them inside `lib/`.
// See round 290; the internal imports have to be re-pointed first.
export 'src/_index.dart';
