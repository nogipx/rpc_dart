// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// Whether [error] is a platform I/O exception whose text describes the
/// SERVER's environment rather than anything the caller can act on.
///
/// Web build: `dart:io` does not exist here, so none of those types can be
/// thrown and the answer is always false.
bool isPlatformInfrastructureError(Object error) => false;
