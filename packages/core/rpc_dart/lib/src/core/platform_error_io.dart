// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:io';

/// Whether [error] is a platform I/O exception whose text describes the
/// SERVER's environment rather than anything the caller can act on.
///
/// These are `Exception`s, so [wireStatusFor] used to forward their message
/// verbatim on the reasoning that an Exception is something the thrower CHOSE
/// to signal. That reasoning holds for an application's own exceptions and for
/// rpc_dart's library diagnostics; it does not hold for these, which nobody
/// throws deliberately at a caller. Measured against a handler that let each
/// escape, identically on http2, websocket and isolate:
///
///     FileSystemException -> "FileSystemException: boom, path = '/etc/private/key.pem'"
///     SocketException     -> "SocketException: refused"
///
/// A path and a hostname, to an unauthenticated peer.
///
/// [HandshakeException] and [CertificateException] extend [TlsException], and
/// [PathAccessException]/[PathExistsException]/[PathNotFoundException] extend
/// [FileSystemException], so the checks below cover them too.
bool isPlatformInfrastructureError(Object error) =>
    error is FileSystemException ||
    error is SocketException ||
    error is HttpException ||
    error is TlsException ||
    error is ProcessException ||
    error is SignalException ||
    error is StdinException ||
    error is StdoutException;
