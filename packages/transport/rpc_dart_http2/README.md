<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_http2

HTTP/2 caller/responder transports and server bootstrap for `rpc_dart`.

- `RpcHttp2CallerTransport` for clients.
- `RpcHttp2ResponderTransport` for servers; `RpcHttp2Server` helper to host responder endpoints.
- gRPC-compatible headers/metadata conversion in `rpc_http2_common.dart`.

Extracted from `rpc_dart_transports` to keep dependencies focused on HTTP/2.
