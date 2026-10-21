// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Everything the implementation may use, with no view on what is public.
///
/// Internals import this; consumers import `package:rpc_dart/rpc_dart.dart`.
/// That separation is what lets the public one be narrowed at all: a file
/// under `lib/` that imports the public barrel makes it a dependency of the
/// implementation, and a `hide` there then deletes names the library needs
/// from itself.
library;

export 'dart:typed_data';

export '../logger.dart';
export '_index.dart';
export 'core/owned_payload.dart';
