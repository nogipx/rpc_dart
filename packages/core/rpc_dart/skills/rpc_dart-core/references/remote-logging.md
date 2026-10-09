<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Remote logging (rpc_dart_log)

`rpc_dart_log` streams `LogController` records from running apps (mobile,
desktop, server, web) to a collector over WebSocket. The collector prints them
with a per-device label and serves them to AI assistants over MCP. Use it to
watch a phone's logs from a dev machine, or to collect logs from several
processes in one terminal. It is a development tool, not a production log
pipeline: the MCP side has no authentication. For production export see
`opentelemetry.md`.

Core logging (`LogController`, `LogScope`, outputs, levels) is in
`logging-and-health.md`. This package adds one `LogOutput` on the app side and
a server on the collector side.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_log: ^0.3.1
```

Two libraries:

| Import | Side | Exports |
| --- | --- | --- |
| `package:rpc_dart_log/rpc_dart_log.dart` | app (web-safe, no `dart:io`) | `LogCollectorOutput`, `DeviceInfo` |
| `package:rpc_dart_log/rpc_dart_log_server.dart` | collector (`dart:io` only) | `LogCollectorServer`, `LogCollectorConsole`, `LogCollectorMcpServer`, `LogCollectorMcpBuffer`, `LogCollectorSession`, `LogCollectorConnectionEvent`, `DeviceConnected`, `DeviceDisconnected`, `TaggedRecord`, `DeviceInfo` |

Neither library re-exports `package:rpc_dart`; import it for `LogController`.

## Rules

- On the app side add a `LogCollectorOutput` to the `outputs:` of your
  `LogController`, or later with `controller.addOutput`. Everything that passes
  the controller's filters is shipped, including the endpoint logs when that
  controller is the endpoints' `logger:`.
- `LogCollectorOutput({required Uri uri, required DeviceInfo device,
  bufferSize = 2000, bufferBytes = 8 MiB, maxInFlight = 32, scopeFilter,
  channelFactory})`.
  The constructor starts connecting at once. `uri` is `ws://host:port`.
- `DeviceInfo({required name, required app, os, appVersion})`. The collector
  labels records `<name>/<sessionId>`; `sessionId` is a random 6-hex-char id
  generated per output instance.
- The output never blocks `write`. Records wait in a buffer while offline and
  are sent once the connection is up. On a drop the connection reconnects with
  exponential backoff (core `RpcClientConnection` defaults: 1 s up to 60 s, no
  attempt limit) and resends unacknowledged records in order.
- `bufferSize` caps buffered plus in-flight records and `bufferBytes` their
  size, as the characters of each record's JSON form. Past either the oldest
  are dropped; the newest is kept even when it alone is larger.
- Only `LogEvent` and finished `LogSpan` records are shipped. `LogSpanStart`
  is skipped.
- The collector side needs `dart:io`. Run it on a dev machine or a server,
  never in the app.
- The collector binds `127.0.0.1` by default. A phone or another host cannot
  reach that; bind `0.0.0.0` (`--bind-all`) on a trusted network only.

## App side

```dart
import 'package:rpc_dart_log/rpc_dart_log.dart';

LogController buildAppLogger({Uri? collector}) => LogController(
  minLevel: RpcLogLevel.debug,
  outputs: [
    ConsoleOutput(format: ConsoleFormat.compact),
    if (collector != null)
      LogCollectorOutput(
        uri: collector,
        device: const DeviceInfo(
          name: 'Pixel 9',
          app: 'com.example.app',
          os: 'Android 15',
          appVersion: '1.2.0+42',
        ),
      ),
  ],
);
```

Pass the controller to every endpoint as `logger:` and get scopes with
`controller.scope('name')`, exactly as in `logging-and-health.md`. A
`LogCollectorOutput` exposes `sessionId`, `isConnected`, `bufferedCount` and
`inFlightCount` for diagnostics.

## Collector side

The quickest collector is the bundled executable:

```text
dart pub global activate rpc_dart_log
rpc_dart_log --bind-all
```

Options: `--port` / `-p` (WebSocket, default 9500), `--mcp-port` (MCP HTTP,
default 9501), `--host` / `-H` (default `127.0.0.1`), `--bind-all` (same as
`--host 0.0.0.0`), `--no-color`, `--help`. The buffer size is not a flag; the
executable keeps 5000 records.

To embed the collector in your own Dart program:

- `LogCollectorServer({host = '127.0.0.1', port = 9500, LogController?
  controller})`. `start()` binds; `boundPort` is the real port (use `port: 0`
  in tests); `stop()` closes everything.
- `onRecord` is a broadcast `Stream<TaggedRecord>` (`deviceLabel`, `record`).
  `onConnection` is a broadcast stream of the sealed
  `LogCollectorConnectionEvent`: `DeviceConnected` / `DeviceDisconnected`, each
  with a `session` (`id`, `deviceName`, `app`, `label`, `connectedAt`).
  `sessions` lists the connected ones.
- Every received record is also added to `controller`. By default that is a
  `LogController(minLevel: RpcLogLevel.internal)` with no outputs; pass your
  own to route remote records into a `RingBufferOutput`, a file, or
  `LogControllerOtelOutput`.
- `LogCollectorConsole({colored = true, IOSink? sink})` renders events:
  `printConnection(event)` and `printRecord(tagged)`. Default sink is stdout.
- `LogCollectorMcpServer.run({host, collectorPort, mcpPort, bufferSize,
  bufferBytes, colored})` starts a collector, a console and the MCP HTTP server together
  (what the executable does). `stop()` stops both.

```dart
import 'package:rpc_dart_log/rpc_dart_log_server.dart';

Future<LogCollectorServer> startCollector({int port = 9500}) async {
  final server = LogCollectorServer(host: '0.0.0.0', port: port);
  final console = LogCollectorConsole(colored: false);
  server.onConnection.listen(console.printConnection);
  server.onRecord.listen(console.printRecord);
  await server.start();
  return server;
}

Future<void> main() async {
  final server = await startCollector(port: 0);
  final logger = buildAppLogger(
    collector: Uri.parse('ws://127.0.0.1:${server.boundPort}'),
  );
  logger.scope('app.startup').info('ready', data: {'build': 42});

  // Records go out asynchronously; dispose() drops whatever is still unsent.
  await Future<void>.delayed(const Duration(seconds: 1));
  logger.dispose();
  await server.stop();
}
```

## MCP

The MCP server answers JSON-RPC 2.0 over HTTP POST at
`http://<host>:<mcpPort>/mcp`. Register it in the assistant's MCP config as an
`http` server with that URL. Two tools: `rpc_log_sources` (devices, buffer,
error counts, scopes, recent errors, trace ids; call it first) and
`rpc_log_get_logs` (filters `count`, `level`, `scope`, `device`, `message`
regex, `traceId` prefix, `type`, `since`, `cursor`, `collapse`, `no_data`,
`context`). Records carry the `traceId` of the `RpcContext` they were logged
under, so `traceId` follows one call across devices.

## Pitfalls

- `LogCollectorServer.stop()` disposes `controller`, including one you passed
  in. Do not share a controller that must outlive the collector.
- `logger.dispose()` (or `output.dispose()`) clears the buffer without
  flushing. Records logged just before exit can be lost.
- `127.0.0.1` in the app means the device itself. From the Android emulator the
  host machine is `10.0.2.2`; a real device needs the machine's LAN address.
- Plain `ws://` is cleartext. Android (`usesCleartextTraffic` / network
  security config) and iOS (App Transport Security) block it unless allowed.
- Importing `rpc_dart_log_server.dart` in a Flutter web or mobile app pulls in
  `dart:io` server code. Apps import only `rpc_dart_log.dart`.
- `RpcLogLevel.internal` records are shipped only if the app controller's
  `minLevel` lets them through; the collector cannot raise verbosity remotely.
- A handshake failure is reported through `dart:developer` `log`, not through
  the `LogController`, so it does not appear in your own outputs.
- `--bind-all` exposes the unauthenticated MCP endpoint on the network.

The full reference, including MCP tool output formats and investigation
workflows, is the package README (`rpc_dart_log`).
