// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Everything the implementation may use, with no view on what is public.
///
/// Eleven files under `lib/` used to import `package:rpc_dart/rpc_dart.dart` —
/// the package's own public barrel — which made that barrel a dependency OF the
/// implementation rather than a surface over it. A `hide` there then deleted
/// names the library needed from itself: 78 analyzer errors, 7 inside `lib/`.
///
/// Internals import this; consumers import `package:rpc_dart/rpc_dart.dart`.
/// That separation is what lets the public one be narrowed at all.
library;

export 'dart:typed_data';

export '../logger.dart';
export '_index.dart';
