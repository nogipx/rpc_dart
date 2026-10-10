---
round: 814
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-25
bench: P-300 — new
commit: yes
severity: S3
release: breaking
---

# Round 814 — a failed websocket connect is a status

## Target

B-288, decided by the owner 2026-10-10 in this round after the measurement:
fix it now, breaking. `RpcWebSocketCallerTransport.connect` threw raw
dart:io types where the http caller reports a gRPC status for the same
failures.

## Hypothesis

Every way the websocket open fails reaches the caller as a dart:io type, so a
`shouldReconnect` cannot tell a refusal on identity (401, 403) from an outage,
and a refused upgrade does not carry its HTTP status at all.

## Before

P-300 at 9e0e3d85:

```
  failure                ws                     http
  refused                SocketException        UNAVAILABLE (14)
  403 from allowUpgrade  WebSocketException     PERMISSION_DENIED (7)
  HTTP 401               WebSocketException     UNAUTHENTICATED (16)
  HTTP 403 / 404 / 503   WebSocketException     7 / 12 / 14
  closed mid-upgrade     HttpException          UNAVAILABLE (14)
  silent (timeout)       TimeoutException       DEADLINE_EXCEEDED (call deadline)
```

## Mechanism

`connectBounded` (the default handshake) read the response status and threw
`WebSocketException("Connection to '<uri>' was not upgraded")`, dropping the
status and putting the uri, userinfo and query included, in the message.
`connect` passed whatever `openWebSocket` threw straight through.
`RpcClientConnection`'s default reconnects on any error, so against a server
that answers 401 it retried forever, and a predicate had nothing typed to
stop on.

## Fix

- `connectBounded` throws `RpcStatusException(grpcStatusFromHttpStatus(status),
  'WebSocket upgrade refused: HTTP <status>')`, with no uri in the message.
- `connect`'s channel factory (used for the first open and every reconnect)
  maps a failure the way the http caller's `_asRpcStatus` does: an
  `RpcException` passes, any other `Exception` becomes UNAVAILABLE, an
  `Error` passes. `headersProvider` runs outside the mapping, so the
  application's own exception reaches it unchanged.
- On the web and on the compressed path the platform hides the status, so a
  refused upgrade there is UNAVAILABLE; the dartdoc and the README table say
  so.

## After

```
  failure                ws                       http
  refused                UNAVAILABLE (14)         14
  403 from allowUpgrade  PERMISSION_DENIED (7)    7
  HTTP 401               UNAUTHENTICATED (16)     16
  HTTP 403 / 404 / 503   7 / 12 / 14              7 / 12 / 14
  HTTP 200 (not ws)      UNKNOWN (2)              INTERNAL (13, content-type)
  HTTP 302               UNKNOWN (2)              2
  closed mid-upgrade     UNAVAILABLE (14)         14
  silent (timeout)       UNAVAILABLE (14)         4 (the call's deadline)
```

Witness `test/a_failed_connect_is_a_status_test.dart`: 401, 403, 404, 503,
the server gate, a close mid-upgrade and `connectTimeout`; GUARD: a
`headersProvider` exception is not rewritten. The two black-hole tests in
`connect_headers_and_timeout_test` now expect UNAVAILABLE.

## Canary

1. The factory mapping off (`1 > 0 ? e : _connectFailure(e)`): the close and
   timeout witnesses fail, `Expected: 'status 14' Actual: 'HttpException'`
   and `'TimeoutException'`; the status witnesses stay green, since
   `connectBounded` throws a status by itself.
2. The status in `connectBounded` off (`throw WebSocketException`): 401, 403,
   404 and the gate fail with `Actual: 'status 14'`; 503 stays green because
   its status is 14 either way. Neither half masks the other's witness (L-01).

## The verdict questions

1. Only the server's answer differs between rows.
2. Yes: types before, codes after, on the same rows.
3. At the caller: what `connect` throws.
4. n/a (a type, not a rate).
5. Quoted.
6. Two halves, two canaries.
7. From the table.
8. No target dismissed; the http2 sibling is B-289.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze` and `test:unit` green. `test:web` was interrupted when the
machine slept: core's suite timed out 11 tests across 89 minutes. Re-run
separately: core on node +2117 in 6 min, `websocket_web_smoke_test` and
rpc_dart_log's `client_web_smoke_test` green.

## Siblings

- websocket: fixed here
- http: already a status (`_asRpcStatus`), the reference this copies
- http2: raw `OSError` on a refused connect: B-289 (owner: breaking, low
  priority)
- channel: n/a, the application opens the channel
- isolate: n/a, no network connect
- wasm: n/a, no network connect
- caller: fixed here (websocket)
- responder: n/a, nothing to connect

## Not fixed

- B-289: http2's connect.
- `openWebSocket`'s own `TimeoutException` text (VM and web) still carries
  the full uri, userinfo and query included, and the UNAVAILABLE message now
  quotes it, so a token in the query reaches `RpcClientConnection`'s warning
  log. Next round's target.
- A refused upgrade on the web and the compressed path is UNAVAILABLE, not
  its HTTP status.

CHANGELOG line (breaking): "rpc_dart_websocket: `RpcWebSocketCallerTransport.connect`
throws `RpcStatusException` instead of dart:io's `WebSocketException`,
`HttpException`, `SocketException` or `TimeoutException`. A refused upgrade
carries its HTTP status mapped by `grpcStatusFromHttpStatus` (401
UNAUTHENTICATED, 403 PERMISSION_DENIED); other failures are UNAVAILABLE."

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-300-what-each-connect-failure-throws.md`. Leads
`../backlog/B-288-websocket-connect-throws-a-raw-httpexception.md` (closed),
`../backlog/B-289-http2-connect-throws-raw-io-errors.md` (new).
