# 1.2.0

- Implemented rich `health()`/`reconnect()` diagnostics for HTTP/2,
  WebSocket and isolate transports, exposing connection metadata and
  supported flags for automation.
- Introduced `WebSocketReconnectManager` with configurable backoff
  strategies and automatic listener re-registration to stabilize client
  reconnections.
- Fixed isolate transport shutdown and health reporting so both host and
  worker isolates surface accurate closed/degraded statuses.
- Updated documentation and examples with diagnostics guidance for
  transport consumers.

# Changelog

## 1.1.2
- fix: websocket connection in flutter web

## 1.1.1
- fix: web io import - remove websocket transport

## 1.1.0

- web: add universal io support to use on web

## 1.0.1

- deps: update rpc_dart

## 1.0.0

- Docs: simplify everything

## 0.1.0

- Initial version.
