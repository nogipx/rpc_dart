---
round: 897
verdict: FIXED
packages: [rpc_dart_socket]
lens: RPC-25
bench: P-349 — new
commit: yes
severity: S2 — "a bounded leak"
release: changelog
---

# Round 897 — a cancel ends a socket connect

## Target

B-310 (rank 4), its socket half. Round 890 gave the websocket caller a
`cancellationToken` and `RpcClientConnection.cancellable` hands one to every
attempt; `connectRpcSocket` took none. RPC-25: one abstraction, the caller
factory, implemented per transport, and one of them missing the stop. The
socket transport before http2, which the owner ranks lower.

## Hypothesis

`dispose()` during a TCP connect to an address that never answers leaves the
socket, and the process, alive until `connectTimeout` or the OS gives up.
Fails if the process exits at once, as it does for a refused port.

## Before

P-349, DISPOSED to process exit:

```
hole     10.255.255.1:9, connectTimeout 30 s    19.6 s, 19.6 s, 7.6 s
hole0    the same, connectTimeout null           14.8 s, 3.5 s
refused  127.0.0.1:9, control                    38-50 ms
```

Bounded by the OS here (macOS gives the SYN up at a varying point) and by
`connectTimeout` where the OS waits longer.

## Mechanism

RPC-25. `connectRpcSocket` awaited `Socket.connect`, which no one can stop.
Round 890's loop gives up the wait on a stop and closes whatever the factory
returns later, but the socket inside the pending connect is not the loop's to
close, and its pending timer keeps the isolate alive.

## After

`connectRpcSocket(cancellationToken:)` connects through `Socket.startConnect`
and cancels the `ConnectionTask` when the token is cancelled, then throws
`RpcCancelledException`; `connectTimeout` is applied to the same task and
still fails UNAVAILABLE. Its doc and the README's reconnect example use
`RpcClientConnection.cancellable`. P-349 after, `token` arm: 24-70 ms over
four runs.

## Canary

`a_cancelled_connect_releases_its_socket_test.dart`, the line that cancels
the task on the token switched off: WITNESS "a cancel ends a connect to an
address that never answers" red, "Expected: throws <Instance of
'RpcCancelledException'> ... threw TestFailure:<the connect ignored the
cancel: it runs until connectTimeout or the OS gives up, and a dispose waits
that long>". GUARDs "a token already cancelled throws before connecting",
"the timeout still fails UNAVAILABLE with a token" and "a connect with a token
that is never cancelled works" green both ways. Restored: `+4`. The witness
also counts the descriptors on 192.0.2.1 with lsof: back to the count before.

## Gate

`melos run analyze`, `format:check`, `license:check`, `api:check`: green.
`test:unit:quiet --no-select`: the first run red on one rpc_dart_isolate test
outside this change ("never reached the failed startup", opened as B-311),
green alone 3/3; the rerun green in full.

## Siblings

- websocket: clean — round 890 (`a_cancelled_connect_closes_its_socket_test.dart`).
- http2: n/a — B-310 keeps it open: `RpcHttp2CallerTransport.connect` takes no
  token for its TCP connect, proxy CONNECT and TLS stages.
- http: n/a — `RpcHttpCallerTransport` opens no connection in its factory;
  each call is its own request.
- isolate: n/a — no network connect.
- wasm: n/a — in-process.
- channel: n/a — in-memory.
- caller: fixed here.
- responder: n/a — the server accepts; it does not connect.
- (not a group member) socket: fixed here.

## Not fixed

The DNS lookup inside `Socket.startConnect` happens before a task exists and
cannot be cancelled; a TCP address is usually a literal here. http2: B-310.

## Links

B-310, round 890, RPC-25, P-342, P-349.
