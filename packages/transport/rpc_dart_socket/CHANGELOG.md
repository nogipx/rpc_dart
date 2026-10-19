<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.1.0

First release: rpc_dart over Unix domain sockets and TCP on the Dart VM.

- **`connectRpcSocket`** opens an `RpcSocketCallerTransport`. Its `ready`
  completes when the server's preface arrives, so `RpcClientConnection` never
  reports Online against a process that is not an rpc_dart server.
- **`RpcSocketServer`** owns its listening socket, restarts by rebinding,
  drains on `stop(drainTimeout:)`, caps connections, and replaces a stale Unix
  socket file left by a crashed process (and nothing else).
- **Opens with core's frame preface**: the client sends `rpcdart` and the
  protocol version, the server answers with the same. A server builds no
  endpoint until the client's has arrived, within `prefaceTimeout`.
- **Runs the transport conformance matrix** over TCP.
