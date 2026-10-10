---
round: 821
commit: 16b052a6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline_dispatch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
scope: unary calls cancelled 1-500 ms after the start over the framed channel pair and over HTTP/1.1 (RpcHttpServer), macOS; not websocket, isolate or wasm measured separately
---

# C-77 — a cancel before dispatch still reaches the handler

RPC-20 asked whether a cancel that arrives before the server has dispatched
the handler is dropped, leaving the handler to run to completion with a
token that never fires. It is not: over the channel pair and over HTTP/1.1,
every handler that started saw the cancel, from 1 ms on; a cancel before the
request is read means the handler never starts. Bench
`../probes/P-304-a-cancel-in-the-first-milliseconds.md`.

On macOS an http cancel reaches a handler only after about 2.1 s (P-295),
so a shorter handler always completes; that is the OS, not the window.

## Control

No cancel: every handler runs to completion.
