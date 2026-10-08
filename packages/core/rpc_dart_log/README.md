<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_log

Real-time remote log collector for rpc_dart applications. Streams structured
log records from any number of clients (mobile, desktop, CLI) over WebSocket
to a central server, with an MCP interface for AI-assisted debugging.

## Architecture

```
App (LogCollectorOutput)
        |  WebSocket (rpc_dart contracts, CBOR)
        v
LogCollectorServer  -->  LogCollectorConsole (terminal)
        |
        v
LogCollectorMcpBuffer
        |
        v
LogCollectorMcpServer  -->  Claude Code / any MCP client
```

---

## Client setup

Add `rpc_dart_log` to your app's dependencies, then attach `LogCollectorOutput`
to your existing `LogController`. `rpc_dart_log.dart` exports only
`LogCollectorOutput` and `DeviceInfo`; import `rpc_dart` for `LogController`.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log.dart';

final controller = LogController(
  minLevel: RpcLogLevel.debug,
  outputs: [
    ConsoleOutput(),
    LogCollectorOutput(
      uri: Uri.parse('ws://192.168.1.10:9500'),
      device: DeviceInfo(
        name: 'Pixel 9',        // shown as label in collector
        app: 'com.example.app',
        os: 'Android 15',       // optional
        appVersion: '1.2.0+42', // optional
      ),
      bufferSize: 2000,         // default; buffered plus in-flight records
      maxInFlight: 32,          // default; unacked records on the wire
    ),
  ],
);
```

The constructor starts connecting at once. `write` never blocks: records wait
in a buffer while offline and are sent once the connection is up.

- On a drop, `LogCollectorOutput` reconnects through the core
  `RpcClientConnection` with its default `ExponentialBackoff`: 1s base, capped
  at 60s, with jitter, no attempt limit. After each reconnect it handshakes
  again and resends unacknowledged records in order.
- `bufferSize` caps buffered plus in-flight records. Past it the oldest records
  are dropped.
- Only `LogEvent` and finished `LogSpan` records are sent. `LogSpanStart` is
  skipped.
- Each instance generates a random 6-hex-char `sessionId`. The collector labels
  its records `<device name>/<sessionId>`, so several connections from the same
  app are distinguishable.
- `dispose()` (or `dispose()` on the controller that owns the output) clears
  the buffer without flushing. Records logged just before exit can be lost.
- A handshake failure is reported through `dart:developer` `log`, not through
  the `LogController`.
- For diagnostics the output exposes `sessionId`, `isConnected`,
  `bufferedCount` and `inFlightCount`.

---

## Server (standalone collector)

### Install

```sh
dart pub global activate rpc_dart_log
```

### Run

```sh
rpc_dart_log [--host 127.0.0.1] [--port 9500] [--mcp-port 9501] [--bind-all] [--no-color]
```

Starts two servers on the same host:
- **WebSocket collector** on `--port` / `-p` (default 9500) -- accepts client connections
- **MCP HTTP server** on `--mcp-port` (default 9501) -- serves AI tools

| Option | Default | Description |
|--------|---------|-------------|
| `--host`, `-H` | `127.0.0.1` | Address to bind. |
| `--bind-all` | off | Bind `0.0.0.0` (all interfaces). Overrides `--host`. |
| `--port`, `-p` | `9500` | WebSocket collector port. |
| `--mcp-port` | `9501` | MCP HTTP server port. |
| `--no-color` | off | Disable ANSI colors. |
| `--help`, `-h` | | Show usage. |

The collector binds loopback by default, so only the same machine can reach it.
A phone or another host needs `--bind-all` or an explicit `--host`. Do this on
a trusted network only: the MCP endpoint and its OAuth flow have no
authentication. The buffer size is not a flag; the executable keeps the last
5000 records.

Terminal output uses ANSI colors with device labels. Colors are also off when
stdout is not a terminal.

### Embed in your own server

`LogCollectorMcpServer.run` starts a collector, a console and the MCP HTTP
server together. This is what the executable does. All parameters are optional
and show their defaults below.

```dart
import 'package:rpc_dart_log/rpc_dart_log_server.dart';

Future<void> main() async {
  final mcp = await LogCollectorMcpServer.run(
    host: '127.0.0.1',
    collectorPort: 9500,
    mcpPort: 9501,
    bufferSize: 5000,
    colored: true,
  );

  // later:
  await mcp.stop(); // stops the MCP server and the collector
}
```

For a collector without MCP, use `LogCollectorServer` and
`LogCollectorConsole` directly:

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_log/rpc_dart_log_server.dart';

Future<void> main() async {
  final server = LogCollectorServer(
    host: '127.0.0.1', // default
    port: 9500,        // default; 0 picks a free port, see boundPort
    controller: LogController(minLevel: RpcLogLevel.internal),
  );
  final console = LogCollectorConsole(colored: false); // sink defaults to stdout
  server.onConnection.listen(console.printConnection);
  server.onRecord.listen(console.printRecord);
  await server.start();
  print('listening on ${server.boundPort}');

  // later:
  await server.stop();
}
```

- `onRecord` is a broadcast `Stream<TaggedRecord>` (`deviceLabel`, `record`).
- `onConnection` is a broadcast stream of the sealed
  `LogCollectorConnectionEvent`: `DeviceConnected` or `DeviceDisconnected`,
  each with a `session` (`id`, `deviceName`, `app`, `label`, `connectedAt`).
  `sessions` lists the connected ones.
- Every received record is also added to `controller`. The default is a
  `LogController(minLevel: RpcLogLevel.internal)` with no outputs. Pass your own
  to route remote records into other outputs.
- `stop()` disposes `controller`, including one you passed in, and with it all
  of that controller's outputs. Do not pass a controller that must outlive the
  collector.

---

## MCP integration (Claude Code)

Add to `~/.claude.json` under your project's `mcpServers`:

```json
{
  "mcpServers": {
    "rpc_dart_log": {
      "type": "http",
      "url": "http://127.0.0.1:9501/mcp"
    }
  }
}
```

Start the collector before opening Claude Code. The MCP server must be running
for Claude to connect.

---

## MCP tools reference

### `rpc_log_sources`

Overview of all connected devices and buffered log data. **Always call this
first** -- it gives enough context to plan the next query without reading logs.

Response includes:
- Connected devices with app ID and connection time
- Buffer size, time range, and current cursor (marked when the buffer is full)
- Total error and warning counts
- Scope breakdown (top 15 by volume) with per-level counts
- Last 5 **unique** errors (deduplicated by device+scope+message, with repeat count)
- TraceIds as 8-char prefixes with error counts: the first 10 of the tracked
  ones in arrival order, then `... +N more`

Example output:
```
Devices (1):
  Pixel 9/a3f9c1 [com.example.app] since 14:32:10
Buffer: 1247 records | 14:32:10 - 15:01:44 | cursor: 1247
Totals: 5 errors, 12 warnings
Scopes:
  engine.websocket: 430 total, 3 err, 12 warn, 88 spans
  sync.engine: 210 total, 1 err
  auth: 45 total
  ... +2 more scopes
Recent errors (3 unique):
  [x47] 15:01:42 [Pixel 9/a3f9c1] ERROR engine.websocket  Connection lost  err=SocketException
  15:00:11 [Pixel 9/a3f9c1] ERROR sync.engine  Sync timeout
  14:58:03 [Pixel 9/a3f9c1] ERROR auth  Token expired
TraceIds (4): a3f9bc12 (2 err), 8d7e2a01, c1240fe4 (1 err), 9b38a10f
```

---

### `rpc_log_get_logs`

Query log records with filters. Returns records in chronological order.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | int | Max records to return (default: 50, clamped to 1..500). The newest matches are kept. Shows `N of N+` when truncated. |
| `level` | string | Minimum level: `internal` `trace` `debug` `info` `warning` `error` `fatal`. Applies to events only; spans pass. |
| `scope` | string | Scope prefix filter. `"engine"` matches `engine.websocket`, `engine.conn`, etc. |
| `device` | string | Device label substring, case-insensitive. `"pixel"` matches `Pixel 9/a3f9c1`. |
| `message` | string | Regex pattern (case-insensitive), matched against an event's message or a span's name. Plain strings work as substring search. |
| `traceId` | string | TraceId prefix (8+ chars from sources, or full ID). Uses `startsWith`. |
| `type` | string | Record type: `"event"` or `"span"`. Omit for both. |
| `since` | string | Time cutoff. Relative: `"30s"`, `"2m"`, `"1h"`. Absolute: `"14:55"`, `"14:55:30"`. |
| `cursor` | int | Return only records after this cursor (from previous response). Overrides `since`. |
| `collapse` | bool | Collapse repeating sequences into `[xN]` / `[xN cycles]` (default: false). |
| `no_data` | bool | Omit structured data fields (default: false). Useful when data is large. |
| `context` | int | Show N lines before/after each match (default: 0, max: 20). Match lines prefixed `>`, context lines `  `. Non-contiguous windows separated by `---`. With context, `count` limits the oldest matches. Disables collapse. |

#### `message` regex examples

```
"timeout"              substring match (case-insensitive)
"timeout|refused"      OR: matches either word
"^conn"                anchored: messages starting with "conn"
"auth.*fail"           wildcard: "auth" followed by "fail"
"(retry|backoff).*\d+" regex: retry/backoff followed by a number
```

Invalid regex patterns fall back to literal substring match.

#### `collapse` output

For a polling loop that emits 2 lines per cycle:

```
[x198 cycles]:
  14:32:10 [Pixel 9/a3f9c1] INFO  engine.poller  tick: start
  14:32:10 [Pixel 9/a3f9c1] INFO  engine.poller  tick: done
14:33:01 [Pixel 9/a3f9c1] ERROR engine.poller  Poller stopped
```

Period detection handles sequences of 1, 2, or 3 lines. Smaller period is
preferred (e.g. `a a a a` collapses as `[x4] a`, not `[x2 cycles]: a a`).

#### `context` output

```
  14:01:10 [Pixel 9/a3f9c1] INFO  engine.ws  sending handshake
> 14:01:11 [Pixel 9/a3f9c1] ERROR engine.ws  Connection lost  err=SocketException
  14:01:11 [Pixel 9/a3f9c1] INFO  engine.ws  scheduling reconnect
---
  14:03:44 [Pixel 9/a3f9c1] INFO  engine.ws  reconnect attempt 3
> 14:03:45 [Pixel 9/a3f9c1] ERROR engine.ws  Connection lost  err=SocketException
  14:03:45 [Pixel 9/a3f9c1] INFO  engine.ws  scheduling reconnect
```

---

## Investigation workflows

### What broke right now?

```
rpc_log_sources
```
Check `Recent errors`. If the error is `[x47]`, it's recurring. If it appeared
once, it may be transient.

### Errors in the last 2 minutes

```
rpc_log_get_logs  level=error  since=2m
```

### What happened around a specific error?

```
rpc_log_get_logs  message=Connection lost  context=5
```

### Follow a single request across devices

```
rpc_log_sources          # find traceId prefix, e.g. a3f9bc12
rpc_log_get_logs  traceId=a3f9bc12
```

### Multiple error types in one query

```
rpc_log_get_logs  message=timeout|refused|reset  level=error
```

### Incremental tail (only new records since last check)

```
rpc_log_get_logs                    # note cursor: 1247 in response
rpc_log_get_logs  cursor=1247       # only records added after that point
```

### High-volume polling / retry noise

```
rpc_log_get_logs  scope=engine.poller  collapse=true  since=5m
```

### Performance: slow spans

```
rpc_log_get_logs  type=span  scope=sync  count=100
```
(AI then identifies slow ones from duration in the output.)

### Specific device only

```
rpc_log_get_logs  device=Pixel  level=error  since=10m
```

---

## Log record format

Each line in `rpc_log_get_logs` output:

```
HH:MM:SS [DeviceLabel] LEVEL scope.name  message  err=...  trace=...  key=val
```

- `LEVEL` is the upper-case level name padded to 5 chars: `INFO `, `DEBUG`,
  `TRACE`, `ERROR`, `FATAL`, `WARNING`, `INTERNAL`
- `err=` present only when error is non-null
- `trace=` present only when traceId is set (full id)
- Data fields are joined as `key=val key=val`; the joined string is truncated
  to 120 chars with a `...` suffix
- Spans show: `HH:MM:SS [device] SPAN  scope  name Nms ok|error  err=...  trace=...`

---

## Transport and protocol

- WebSocket transport (`rpc_dart_websocket`)
- CBOR codec via `rpc_dart` contracts
- Messages: `LogCollectorHandshake` → `LogCollectorWelcome`, then stream of `LogCollectorRecord` → `LogCollectorAck`
- MCP: plain JSON-RPC 2.0 over HTTP POST (no SSE, no streaming)
- OAuth discovery endpoints for Claude Code compatibility (local no-auth stub)

---

## Buffer behavior

- Server buffers the last N records (5000 in the executable; `bufferSize` in
  `LogCollectorMcpServer.run`, `maxRecords` in `LogCollectorMcpBuffer`)
- When full, oldest records are evicted. Scope stats and error/warning totals
  are cumulative, so they can count evicted records
- Scope stats capped at 500 scopes; oldest evicted when full
- TraceId index capped at 500 entries; oldest evicted when full
- Cursor increases monotonically across evictions. If records after a cursor
  were evicted, `rpc_log_get_logs` returns the whole buffer prefixed with
  `WARNING: cursor stale`, so a tail consumer can reset
