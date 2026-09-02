<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.3.0

### Fixed

- The MCP buffer's per-scope statistics are bounded; scope names are
  effectively unbounded in cardinality, so the map grew without limit.

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.2.2

- Stop silently swallowing two error sites:
  - `LogCollectorServer` (`log_server.dart`): a failed WebSocket upgrade was
    dropped via `onError: (_) {}`, making failed client connections invisible.
    Now logged to `stderr` at a non-fatal severity; server control flow is
    unchanged.
  - `LogCollectorOutput` (`log_output.dart`): a handshake failure dropped the
    connection and retried but never logged why, making connection problems
    undebuggable. Now logs the caught error via `dart:developer.log`, a
    low-level diagnostic that does NOT re-enter the `LogController`/`LogOutput`
    pipeline this class feeds (avoiding a logging-recursion loop). Existing
    retry/reconnect behavior is unchanged.

## 0.2.1

**Client (`LogCollectorOutput`):**
- Reconnect handling now delegates to `RpcClientConnection` (from
  `package:rpc_dart`), the canonical transport-agnostic auto-reconnect wrapper,
  instead of a hand-rolled backoff loop on top of
  `RpcWebSocketCallerTransport.reconnect`. `RpcClientConnection` owns the backoff
  and attempt limits, rebuilds the WebSocket transport via the existing
  `channelFactory` on every attempt, and exposes a stable proxy transport. The
  `RpcCallerEndpoint` and caller are built once on that proxy and survive
  reconnects. This removes the duplicated reconnect/backoff code
  (`_scheduleReconnect`, the manual attempt counter, direct transport
  `reconnect()` calls).
- Lifecycle is driven off `RpcClientConnection.state`: on the transition to
  `RpcClientOnline` the client re-handshakes (device info) and flushes the
  buffer; while not online it buffers. Same observable guarantees as before --
  bounded buffer (drop oldest), pipelined fire-and-forget sends that never block
  `write`, ordered flush, and no loss across reconnect (unacked in-flight
  records are requeued at the buffer head and re-sent after the next Online).
- Public API unchanged: `channelFactory`, `sessionId`, `isConnected`,
  `bufferedCount`, `inFlightCount`.

## 0.2.0

Protocol redesign of the client transport path (breaking).

**Client (`LogCollectorOutput`):**
- Web-safe: the client library (`package:rpc_dart_log/rpc_dart_log.dart` ->
  `LogCollectorOutput` + `DeviceInfo` + contracts) no longer pulls any
  `dart:io` server code, so it compiles and runs on dart2js / node / browser.
  Server-side code stays behind `rpc_dart_log_server.dart`. Mobile and
  Flutter-Web apps embed exactly this client.
- Reconnect now uses the WebSocket transport's built-in
  `RpcWebSocketCallerTransport.reconnect`: the transport, endpoint and caller
  are built once and reused across reconnects via a channel reconnect factory,
  instead of rebuilding the whole endpoint per attempt.
- Record sends are pipelined fire-and-forget on the logging hot path: `write`
  never blocks and the pump issues the next send without awaiting the previous
  ack, so per-record round-trip latency no longer caps throughput. The empty-Ack
  reply is consumed off the hot path only to advance the bounded in-flight
  window; unacked in-flight records are requeued at the buffer head on reconnect
  (order preserved, no loss).
- New public surface for diagnostics/tests: `channelFactory` constructor param,
  `sessionId`, `isConnected`, `bufferedCount`, `inFlightCount`.

## 0.1.1

**Fixes (audit):**
- Client output (`LogCollectorOutput`): the re-buffer path on send failure now enforces `bufferSize` (was unbounded), and the flush is serialized -- a record is removed from the buffer only after its send succeeds, preserving order and preventing loss/reordering on reconnect.
- Server handshake is now idempotent per connection: a duplicate handshake no longer leaks the previous session or emits a spurious `DeviceConnected`.
- MCP server: a malformed/non-object JSON body now returns a JSON-RPC `-32700` parse-error envelope (HTTP 200) instead of an HTTP 500 with a stack trace.
- `mcp_buffer`: a stale cursor (older than the eviction horizon) is now signalled with a reset warning instead of silently returning the whole buffer; eviction uses a `ListQueue` for O(1) removal.

**Security:**
- The collector and MCP servers now bind `127.0.0.1` by default (was `0.0.0.0`); use `--bind-all` to opt into binding all interfaces.
- The MCP OAuth `authorize` endpoint now allowlists loopback `redirect_uri` targets only (rejecting open-redirect attempts) and issues a random per-request token instead of a static one. The flow remains dev-only/unauthenticated.

## 0.1.0

- Initial release: real-time remote log collector over WebSocket (`LogCollectorOutput` client, `LogCollectorServer` + `LogCollectorConsole`), and `LogCollectorMcpServer` for Claude Code integration.
