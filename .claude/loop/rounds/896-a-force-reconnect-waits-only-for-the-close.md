---
round: 896
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-16
bench: P-348 — new
commit: yes
release: none
---

# Round 896 — a force reconnect waits only for the close

## Target

B-304 (rank 7), in core and in the file rounds 890-891 just changed:
`forceReconnect()` runs `_proxy.detach()` and starts the connect loop only in
its `.then`. RPC-16, a state read across an await: during the detach the
connection still reads Online, `isReconnecting` reads the guard the loop has
not set yet, and `_awaitNextAttempt` answers from `_state`. The lead's open
question was how long that window is on a real transport, and whether a retry
spends its attempts in it.

## Hypothesis

When the old path is dead, the old transport's close is slow, and for that
long calls are refused with `reconnecting: false` while `awaitReconnect()`
answers healthy at once, so `RpcRetryInterceptor` spends its attempts before
the reconnect starts. Fails if the window is shorter than the retry's first
backoff (200 ms by default).

## Before

P-348, `forceReconnect()` to Online again, through a relay that freezes the
old connection:

```
             live    frozen
websocket    12 ms   8 ms
socket        7 ms   5 ms
http2        15 ms   8 ms
```

Core arm, a fake transport with a slow close:

```
close 0 ms     state@10ms Online  awaitReconnect healthy in 0 ms  call ok, 1 attempt   Online again at 0 ms
close 2000 ms  state@10ms Online  awaitReconnect healthy in 0 ms  call ok, 1 attempt   Online again at 2004 ms
```

The window is the old transport's close, and on every transport here a close
over a dead path took under 10 ms. All three arms had no call in flight; for
http2 a call in flight is not measured here (its close RSTs every stream
before `finish()`, read, not run), and its `finish()` is bounded by the 2 s
graceful budget either way. The retry's first backoff (200 ms) lands after
the reconnect.

## Mechanism

n/a (CLEAN). The window exists in core and is as long as `close()` of the
transport being dropped. The fake shows the half B-304 did not expect: a
transport that reports `isClosed` only at the end of its close keeps serving
calls during it, so nothing is refused; the in-repo transports set the flag
at the start, but their close is too short for a retry to land in it.

## After

No change.

## Canary

n/a (CLEAN). The control is the bench's own `live` arm and the 0 ms core arm.

## Gate

n/a — no code change.

## Siblings

- websocket: clean — P-348, 8 ms over a frozen path.
- http: n/a — `RpcHttpCallerTransport` holds no connection to drop; each call
  is its own request.
- http2: clean — P-348's http2 file, 8 ms.
- isolate: n/a — the port closes at once; no network path to go dead.
- wasm: n/a — in-process.
- channel: n/a — in-memory.
- caller: clean — P-348 is the caller side.
- responder: n/a — `forceReconnect()` is a client-connection method.
- (not a group member) socket: clean — P-348's socket file, 5 ms.

## Not fixed

The state stays Online and `awaitReconnect()` answers healthy for as long as
the old transport's close runs. Measured under 10 ms on every transport in
the repository; only a third-party transport with a slow `close()` would
show it.

## Links

B-304, RPC-16, rounds 890-891, P-348.
