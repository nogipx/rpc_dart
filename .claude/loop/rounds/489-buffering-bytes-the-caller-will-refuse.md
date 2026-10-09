---
round: 489
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-17
bench: P-128 — new
commit: yes
severity: S1
---

# Round 489 — buffering bytes the caller will refuse

## Target

B-98, fifth in the audit's rank and the second HTTP/1.1 one. A memory DoS any
client can reach by calling a method that streams until cancelled.

Lens RPC-17 — the limit exists but measures the wrong thing, or runs too late.
Here the limit exists on the REQUEST side of this very file, with a comment
explaining its exact form, and the response side has none.

## Hypothesis

`sendMessage` appends every response frame to `pending.bodyBuffer` until
end-of-stream and nothing caps it, so what the server retains is proportional to
what the handler produces. Refuted if some layer above bounded it, or if the
buffer were flushed incrementally — HTTP/1.1 cannot, which is the premise.

## Before

```
ascending scales, 64 KiB ceiling
  512 KiB produced    peak RSS  +8720 KiB   caller received 0  status=8
  2048 KiB produced   peak RSS +12608 KiB   caller received 0  status=8
  8192 KiB produced   peak RSS +40208 KiB   caller received 0  status=8
  32 KiB (control)    peak RSS     +0 KiB   caller received 4  ok
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b98_unbounded_response.dart`

**Both halves of the lead are confirmed in one table.** The retention tracks
production, and `received 0` says the bytes were retained to be thrown away: the
caller refuses any body over the same ceiling.

## Mechanism

One `BytesBuilder` per response, appended per frame, drained only at
end-of-stream. A subscription or a tail never reaches end-of-stream, so the
buffer is the handler's whole output.

## After

```
largest first, one variable
  8192 KiB, no cap    peak RSS +57664 KiB
  8192 KiB, capped    peak RSS +11456 KiB
```

Bounded by `maxFramedMessageBytes` — the same number the request side uses, and
for a stronger reason than symmetry: past it the bytes cannot be delivered. Over
the ceiling the response is ended with RESOURCE_EXHAUSTED in ordinary response
headers, which is where this wire format carries a status.

The pending entry STAYS in `_pending` afterwards, marked `answered`. Removing it
made every later frame log "no pending response" — a line per message for a
stream that runs until cancelled.

## Canary

`if (pending.bodyBuffer.length > limit && 1 < 0)` — the WITNESS fails with
`Expected: a value less than <200> / Actual: <200>`, "the answer waited for the
handler to finish, which means the whole 1.6 MiB was resident first". Both
GUARDs stay green.

**The first witness I wrote passed on both sides and had to be replaced.** It
asserted `RESOURCE_EXHAUSTED` and `received 0` — both true before the fix too,
because the caller refused the oversized body it had already been sent. What
distinguishes is WHEN the answer comes, so the test reads the handler's own
counter at the moment the caller is answered. That needed the handler to be a
real feed (an `await` between items); without one the whole loop runs in a
single turn and the counter says nothing about the transport.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

One test of mine was flaky before it shipped: `GUARD: the handler keeps running`
counted after a fixed 500 ms and failed once, passed once, on identical code. It
polls to a deadline now — `methods/tests.md` item 1, paid for again.

## Not fixed

**The handler is not stopped, only its output dropped.** It runs to completion,
which the third test pins deliberately. Stopping it needs a reset this transport
does not have — the same absence B-97 hit and which B-140 will close.

**The ceiling is the effective policy, not the configured one.** A responder
built with no `securityPolicy` now bounds responses at the default 16 MiB where
it previously had none. That is a behaviour change for an unconfigured server,
and it is the honest reading of the measurement: the caller refuses past that
point regardless, so nothing deliverable is lost. B-150 is the lead about that
null default.

## Links

Lens RPC-17. Bench P-128 (new). Lead B-98 (closed). B-140 inherits the reset;
B-150 owns the null policy default.
