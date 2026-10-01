---
round: 569
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-08
bench: P-190 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
---

# Round 569 — the cancel that was a request

## Target

`B-175` from the audit intake, taken because its sibling is already settled: the HTTP/1.1 caller
fixed this exact shape and its `sendMetadata` still carries the comment describing it. A lead
whose answer can be compared against a working sibling is the cheapest kind to measure, and
`C-61` says the intake's own confidence lines decide nothing.

Breadth first: `grep` for `/Unknown/Unknown` across every package's `lib/` returns **two** hits —
this site, and HTTP/1.1's comment about having removed it. One instance.

Lens RPC-08: one rule, two transports, applied on one of them.

## Hypothesis

`sendMetadata` defaults a missing methodPath and calls `makeRequest`, which OPENS a stream. Core
sends exactly one such frame — the cancellation notice, after `resetStream` reports it could not
deliver the cancel — so a cancel becomes a request.

## Before

```
ARM 1  cancel after the call completed
    resetStream returned       false
    paths after the call       [/Svc/Echo]
    paths after the cancel     [/Svc/Echo, /Unknown/Unknown]

ARM 3  a second OPENING frame on a LIVE id
    activeStreams before       1
    the second frame           accepted
    paths the server saw       [/Svc/Slow, /Svc/Again]
    activeStreams after        1
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/b175_phantom_stream.dart`, against a
server that records every `:path` it accepts.

Both halves of the lead, and the second is the sharper one: `_activeStreams[streamId] = stream`
overwrote, so the first stream was **stranded with nothing tracking it** while the count still
read 1.

## Mechanism

On HTTP/2 only an opening frame carries client metadata — there is no "send metadata on an
existing stream" — so `methodPath ?? '/Unknown/Unknown'` turned every pathless frame into a new
request. `resetStream` returns false exactly when the id has no stream, which is the only case
in which core reaches the fallback.

## After

```
ARM 1  paths after the cancel     [/Svc/Echo]
ARM 3  the second frame           RpcStatusException
       paths the server saw       [/Svc/Slow]
       activeStreams after        1      <- the FIRST stream, still tracked
```

Two conditions, the first copied from the sibling: no methodPath means nothing goes on the wire
(a cancel on this transport is an RST_STREAM, which `resetStream` already sends), and an id that
already has a stream refuses a second opening frame instead of overwriting it.

## Canary

```
A. `?? '/Unknown/Unknown'` restored, the early return disabled
     Expected: ['/Svc/Echo']
       Actual: ['/Svc/Echo', '/Unknown/Unknown']
     a cancel is not a request; opening /Unknown/Unknown gives the server a
     call it must answer and leaves the real one untouched

B. the overwrite guard disabled
     Expected: throws <Instance of 'RpcStatusException'>
       Actual: <Instance of 'Future<void>'>   Which: emitted <null>
```

**ARM 2 of the probe is why the second canary needed its own arm.** A second `sendMetadata`
after an ANSWERING server has already ended the stream takes the no-methodPath branch, so it
reads as fixed while saying nothing about the overwrite. The overwrite needs a server that never
answers, which is what the probe's third arm and the test's second one use.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http2 +268
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2171 / 2171, REUSE compliant
```

## Not fixed

**Whether the phantom stream reached the handler is not measured.** The server here records
`:path` and answers; what a real responder does with `/Unknown/Unknown` — UNIMPLEMENTED, and
whether that costs it a handler slot or a log line — was not driven. The HTTP/1.1 round that
fixed the sibling recorded "answered UNIMPLEMENTED, preflight-failing in a browser", so the
shape is known; it is not re-established here.

**The third claim in the lead's prose is not an instance.** "Cleared by reconnect" and "reserved
but never opened" are two more ways to reach `resetStream == false`, and both now take the same
early return — but neither was driven, so they are covered by construction rather than witnessed.

**No dart2js arm**: `rpc_dart_http2` is `dart:io`-only.

## Links

Lead `../backlog/B-175-the-http2-cancel-opens-a-phantom-stream.md` — CLOSED.
Bench `../probes/P-190-what-the-server-sees-when-a-cancel-has-no-stream.md` — new.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [569]`.
Lesson: none. The sibling comparison is catalog `U-14` and `RPC-08` already carries it; what this
round adds is one more instance of a rule fixed on one transport and left on another.
