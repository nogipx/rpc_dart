// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

/// `Request.context` key under which [RpcHttpServer] gives each request a
/// `Future<void>` that completes when the client's connection has ended.
///
/// Absent when the responder transport is mounted on any other shelf server;
/// there a caller's cancel does not reach the handler.
const String kRpcHttpPeerGoneKey = 'rpc_dart_http.peer_gone';
