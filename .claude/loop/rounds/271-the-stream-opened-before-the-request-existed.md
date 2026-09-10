---
round: 271
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-05
bench: P-22 — new
commit: yes
---

# Round 271 — the stream opened before the request existed

## Target

`rpc_dart_http` — the one transport with no round of its own in 201-270. It
appears in the journal only inside negatives (C-04, C-27, C-28) and as a fixed
instance in RPC-17's evidence; every lens that has produced findings lately was
derived on core, websocket, http2 and isolate. `next` offered three stale sweeps
(RPC-02, RPC-09, RPC-14, all over the same three core files that 243/244/246
already found clean) and six leads that are blocked on cost or on an owner
decision. B-06's own instruction is what decided it: **rescan the package rather
than work from a list.**

RPC-05 is the lens the finding landed under: a limit charged, or released, at
the wrong point of the lifecycle.

## Hypothesis

`RpcHttpResponderTransport._handleRequest` emits the opening metadata frame
BEFORE it reads the request body. Its error path removes the transport's own
`_pending` entry and nothing else, so a body that never completes may leave a
stream open in the responder pipeline — and `RpcHttpServer` keeps ONE
`RpcResponderEndpoint` for the whole server (its own doc comment, line 16), so
that budget is shared by every client rather than being per connection the way
C-29 assumes.

## Before

8 raw sockets send gRPC request headers with `content-length: 100000`, write a
5-byte gRPC length prefix and die. `maxActiveStreams: 8`.

```
arm      bodyReadTimeout  pendingRequests  openStreams  an ordinary call
ok       -                0                0            OK
abort    none             8                8            HTTP 503
timeout  500ms            0                8            RpcStatusException(8)
                                                        Too many concurrent
                                                        streams (max: 8)
```

`timeout` is the witness. It is the configuration the docs point at for exactly
this attack, and it works on ONE of the two budgets: `pendingRequests` is back
to 0 — the 408 fired, as documented — while the pipeline stays full. Nothing
releases those streams until `halfOpenStreamTimeout`, 60s by default. The peer
spent one TCP connection and ~110 bytes each.

`abort`'s 503 is a DIFFERENT limit — the transport's own
`_pending.length >= maxActiveStreams` — and is the documented slowloris surface,
which is why it is not the witness and why it still reads 503 after the fix.

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/half_open_after_body_failure.dart`

Both numbers are the library's own counters: `openStreams` is
`_respStreams.length` (`responder_pipeline.dart:571`), `pendingRequests` is
`_pending.length` (`rpc_http_responder_transport.dart`, through `health()`).

## Mechanism

The opening frame announces a stream the transport cannot yet feed, and there is
no path by which it can withdraw it — every teardown the transport owns
(`_pending`, `_idManager`) is invisible to the pipeline. The pipeline's own
guard, `_armHalfOpenReclaim`, is armed and correct, but it bounds TIME (60s) and
the attacker controls RATE: ~68 aborted requests a second keep the default
4096-slot table full indefinitely, at ~33 KiB of parked state each (C-29).

## After

The metadata frame moved to sit immediately before the payload frame, so the
stream is announced only once the whole request is in hand. Same probe:

```
arm      bodyReadTimeout  pendingRequests  openStreams  an ordinary call
ok       -                0                0            OK
abort    none             8                0            HTTP 503
timeout  500ms            0                0            OK
```

The pipeline is untouched by an aborted body under either configuration, and
`bodyReadTimeout` now closes the hole it was documented to close.

## Canary

`test/aborted_body_frees_the_pipeline_stream_test.dart` — with the emit put
back where it was, the witness failed with

    Expected: <0>
      Actual: <4>
    and it must leave nothing parked in the pipeline either

at 2s, an assertion rather than a timeout, while the GUARD test kept passing.
The witness waits for the RISE before asserting zero, so it cannot pass on a
server the aborted requests never reached.

**The rise-check as first written was FLAKY, and the owner caught it in a full
suite run**: `Expected: <4> Actual: <0>`. It demanded `pendingRequests` reach 4
SIMULTANEOUSLY, which is a stronger question than the guard needs — the sockets
are opened one at a time, and under load `bodyReadTimeout` can answer the first
before the last one connects, so the count never reaches 4 at any single
instant. It now takes the PEAK over the window and asserts it rose above zero.
Re-canaried after the change: the real witness still fails 4-versus-0 with the
fix off, so the de-flaking did not weaken it.

> **A guard that asserts more than it means will flake, and the extra strictness
> buys nothing.** "Did these requests reach the transport at all" is the
> question; "were all four in flight at once" is an implementation detail of how
> the bench opens sockets.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.
`rpc_dart_http` on its own: 120 tests, all passed.

## Not fixed

The `abort` arm with no `bodyReadTimeout` still wedges the transport's own
budget at 8 of 8. That is slowloris, it is bounded by `maxActiveStreams`, and
`bodyReadTimeout` is the documented answer — which, after this round, actually
works. Left as it is rather than defaulting the timeout on: a default that
rejects `Expect: 100-continue` clients is a policy choice the transport
deliberately leaves open, and the doc comment on `bodyReadTimeout` argues that
case with numbers.

Also filed this round, not measured by it: the missing records for rounds 269
and 270, which were committed (`ada68beb`, `33090229`) with their findings only
in the commit bodies. `loop.py next` reads `rounds/`, so it had begun handing
out 269 a second time. Transcribed, no claim added.

## Links

Lens RPC-05 (`applied:` gains 271). Bench P-22 — new. C-29's "responder
endpoints are PER CONNECTION" now carries the exception this round found:
`RpcHttpServer` is the one server where it is not.
