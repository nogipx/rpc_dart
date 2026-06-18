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
to your existing `LogController`:

```dart
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
      bufferSize: 2000,         // records buffered while disconnected
    ),
  ],
);
```

`LogCollectorOutput` auto-reconnects with exponential backoff (1s..15s) and
flushes the buffer on reconnect. Each instance generates a unique session ID
so multiple connections from the same app are distinguishable.

---

## Server (standalone collector)

### Install

```sh
dart pub global activate --source path packages/core/rpc_dart_log
```

### Run

```sh
rpc_dart_log [--host 0.0.0.0] [--port 9500] [--mcp-port 9501] [--buffer 5000]
```

Starts two servers:
- **WebSocket collector** on `--port` (default 9500) -- accepts client connections
- **MCP HTTP server** on `--mcp-port` (default 9501) -- serves AI tools

Terminal output uses ANSI colors with device labels. Pass `--no-color` to disable.

### Embed in your own server

```dart
import 'package:rpc_dart_log/rpc_dart_log_server.dart';

final mcp = await LogCollectorMcpServer.run(
  host: '0.0.0.0',
  collectorPort: 9500,
  mcpPort: 9501,
  bufferSize: 5000,
);

// later:
await mcp.stop();
```

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
- Buffer size, time range, and current cursor
- Total error and warning counts
- Scope breakdown (top 15 by volume) with per-level counts
- Last 5 **unique** errors (deduplicated by device+scope+message, with repeat count)
- Active traceIds as 8-char prefixes with error annotation

Example output:
```
Devices (1):
  Pixel 9/a3f (com.example.app) since 14:32:10
Buffer: 1247 records | 14:32:10 - 15:01:44 | cursor: 1247
Totals: 5 errors, 12 warnings
Scopes:
  engine.websocket: 430 total, 3 err, 12 warn, 88 spans
  sync.engine: 210 total, 1 err
  auth: 45 total
  ... +2 more scopes
Recent errors (3 unique):
  [x47] 15:01:42 [Pixel 9/a3f] ERROR  engine.websocket  Connection lost  err=SocketException
  15:00:11 [Pixel 9/a3f] ERROR  sync.engine  Sync timeout
  14:58:03 [Pixel 9/a3f] ERROR  auth  Token expired
TraceIds (4): a3f9bc12 (2 err), 8d7e2a01, c1240fe4 (1 err), 9b38a10f
```

---

### `rpc_log_get_logs`

Query log records with filters. Returns records in chronological order.

| Parameter | Type | Description |
|-----------|------|-------------|
| `count` | int | Max records to return (default: 50, max: 500). Shows `N of N+` when truncated. |
| `level` | string | Minimum level: `internal` `trace` `debug` `info` `warning` `error` `fatal` |
| `scope` | string | Scope prefix filter. `"engine"` matches `engine.websocket`, `engine.conn`, etc. |
| `device` | string | Device label substring, case-insensitive. `"pixel"` matches `Pixel 9/a3f`. |
| `message` | string | Regex pattern (case-insensitive). Plain strings work as substring search. |
| `traceId` | string | TraceId prefix (8+ chars from sources, or full ID). Uses `startsWith`. |
| `type` | string | Record type: `"event"` or `"span"`. Omit for both. |
| `since` | string | Time cutoff. Relative: `"30s"`, `"2m"`, `"1h"`. Absolute: `"14:55"`, `"14:55:30"`. |
| `cursor` | int | Return only records after this cursor (from previous response). Overrides `since`. |
| `collapse` | bool | Collapse repeating sequences into `[xN]` / `[xN cycles]` (default: false). |
| `no_data` | bool | Omit structured data fields (default: false). Useful when data is large. |
| `context` | int | Show N lines before/after each match (max: 20). Match lines prefixed `>`, context lines `  `. Non-contiguous windows separated by `---`. Disables collapse. |

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
  14:32:10 [Pixel 9/a3f] INFO   engine.poller  tick: start
  14:32:10 [Pixel 9/a3f] INFO   engine.poller  tick: done
14:33:01 [Pixel 9/a3f] ERROR  engine.poller  Poller stopped
```

Period detection handles sequences of 1, 2, or 3 lines. Smaller period is
preferred (e.g. `a a a a` collapses as `[x4] a`, not `[x2 cycles]: a a`).

#### `context` output

```
  14:01:10 [Pixel 9/a3f] INFO   engine.ws  sending handshake
> 14:01:11 [Pixel 9/a3f] ERROR  engine.ws  Connection lost  err=SocketException
  14:01:11 [Pixel 9/a3f] INFO   engine.ws  scheduling reconnect
---
  14:03:44 [Pixel 9/a3f] INFO   engine.ws  reconnect attempt 3
> 14:03:45 [Pixel 9/a3f] ERROR  engine.ws  Connection lost  err=SocketException
  14:03:45 [Pixel 9/a3f] INFO   engine.ws  scheduling reconnect
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
HH:MM:SS [DeviceLabel] LEVEL  scope.name  message  err=...  trace=...  key=val
```

- `LEVEL` is padded to 5 chars: `INFO `, `ERROR`, `WARN `, `DEBUG`, `FATAL`, `SPAN `
- `err=` present only when error is non-null
- `trace=` present only when traceId is set
- Data fields truncated to 120 chars with `...` suffix
- Spans show: `HH:MM:SS [device] SPAN  scope  name  Nms ok|error`

---

## Transport and protocol

- WebSocket transport (`rpc_dart_websocket`)
- CBOR codec via `rpc_dart` contracts
- Messages: `LogCollectorHandshake` → `LogCollectorWelcome`, then stream of `LogCollectorRecord` → `LogCollectorAck`
- MCP: plain JSON-RPC 2.0 over HTTP POST (no SSE, no streaming)
- OAuth discovery endpoints for Claude Code compatibility (local no-auth stub)

---

## Buffer behavior

- Server buffers last N records (default 5000, configurable via `--buffer`)
- When full, oldest records are evicted (scope stats may be slightly overstated)
- Cursor is monotonically increasing across evictions -- always safe to use for incremental tail
- TraceId index capped at 500 entries; oldest evicted when full
