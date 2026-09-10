---
round: 309
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: none
commit: yes
---

# Round 309 — three drains, one of them quiet

## Target

The candidate round 308's own record named and left: the `_drain` poll loop in
`RpcWebSocketServer`, `RpcHttpServer` and `RpcHttp2Server`.

Taken now for a reason beyond finishing a list. 308 applied RPC-25 to
`rpc_dart_http` and `rpc_dart_http2` only, so **`rpc_dart_websocket` had been
touched for documentation and nothing else** — the owner's mandate names five
packages, and the abstraction clause had reached three of them. The servers are
where websocket's shared machinery lives.

## Hypothesis

RPC-25 again: three siblings, one shape, and a drift where nothing can see it.

## Before

Three copies of "poll a count until zero or the budget expires":

```
RpcWebSocketServer._drain          18 lines
RpcHttpServer._drainRequests       27
RpcHttp2Server._drain              20   (plus its GOAWAY step)
```

## Mechanism

Step 3 — what does each copy do that the others do not — found the drift in the
LOGGING, which is the whole output of a drain:

```
                     start log   success log
websocket            info        (none)
http                 debug       (none)
http2                info        info "Drain complete"
```

Two disagreements about the same event. The `debug`/`info` split means an
operator watching an HTTP/1.1 deploy at the default level sees nothing while the
other two servers announce the drain. And only one of three ever says the drain
CONVERGED — so on the other two, "budget expired, closing anyway" is the single
line, and its absence is the only signal that anything went well. An absence is
not a signal.

`drainUntilIdle` now owns the loop and all three logs, so the three servers
report a drain identically.

What stayed server-specific, because it is real:

- **the COUNT.** websocket and http2 sum `activeResponders` across endpoints;
  http asks its single transport for `pendingRequests` through `health()`. The
  parameter is `FutureOr<int> Function()` for exactly that — one is sync, one is
  async.
- **the GOAWAY.** http2 sends it to every live connection before polling,
  because an existing HTTP/2 connection can still open streams and the drain
  would not converge without it. That stays in `RpcHttp2Server`.
- **the noun.** `unit: 'request'` for http, `call` elsewhere — "3 in flight" is
  not worth reading without it.

`_notify` was the other named candidate and is **deliberately NOT merged**.
Step 3 found no drift: the two copies in `RpcWebSocketServer` and
`RpcHttp2Server` are the same eight lines with the same message. RPC-25's bar is
the divergence, not the line count, and merging would add a public promise to
core to save eight lines. Recorded so the next round does not take it as
oversight.

## After

```
                      lines
three copies             65
drainUntilIdle (core)    36 of code

servers, net            -38   (21 insertions, 59 deletions)
```

Behaviour identical except the logging, which is now uniform — and strictly more
informative on two of three servers.

## Canary

The suite proves the extraction changed nothing else: 14 packages, 0 failures,
including the websocket and http2 drain tests that assert a call RETURNS its
real answer under `stop(drainTimeout:)` rather than failing UNAVAILABLE.

It does not witness the log unification, and nothing automated does — the same
honest limit every round in this mandate has carried for prose. The check is the
table above: three call sites, one implementation, one set of messages.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1309/1309.

## Not fixed

`rpc_dart_isolate` has had RPC-23 (302) and an RPC-24 check (307, clean) but no
RPC-25 application — because it has no sibling to drift against. It ships one
transport in two platform variants, and `isolate_transport.dart` /
`isolate_transport_web.dart` implement DIFFERENT mechanisms (SendPort against
Worker), not the same one twice. RPC-25 needs siblings; the correct result here
is that the lens does not apply, and that is a finding rather than a gap.

B-30 is still open and still the owner's call.

## Links

RPC-25 (`applied:` gains 309). Second application, and it sharpens the lens in
two ways: the drift can be in the LOGGING rather than the logic — the copies
agreed on what to do and disagreed on what to say about it — and a candidate
with no drift is correctly left alone, which `_notify` now records as precedent.
