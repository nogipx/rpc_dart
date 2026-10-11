---
round: 818
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-02
bench: none — two probes, below
commit: yes
release: none
---

# Round 818 — the refusal trailers re-swept again

## Target

`loop.py stale`: the RPC-02 sweep (round 775, 8d804d9f) had 49 changes along
its paths, among them two new refusal paths (round 809's oversize answer,
round 803's item budget). The lens asks the next round to ablate, not
re-read.

## Hypothesis

A refusal trailer added since round 775 carries a diagnosis longer than the
policy that refused, so the caller gets a different status, or none.

## Before

Every `forTrailer(` call read to its closing paren by a script over core,
websocket, http, isolate and http2:

```
  23 sites: 17 with a message (16 capped), 6 without
  uncapped: unary/responder.dart _dropLateResponse (CANCELLED, token reason)
  new since 775: frame_multiplexed_channel._failChannel (809), capped
```

## Mechanism

n/a (CLEAN).

## After

Probe `packages/test/rpc_dart_conformance/.dart_tool/probe/r818_oversize_trailer_cap.dart`
(the conformance byte pipe, server `maxMessageLengthBytes` 1024, a 64 KiB
request):

```
  server maxHeaderValueBytes   caller gets
  8192 (control)               8 "Incoming frame payload too large: 65549 bytes (max: 1029)"
  64                           8, the text cut to 64
  48                           8, the text cut to 48
  48, cap ablated              8, the full text
```

Probe `packages/core/rpc_dart/.dart_tool/probe/r818_long_cancel_reason.dart`
(a handler cancels its own token, `maxHeaderValueBytes` 1024):

```
  reason 10 chars     CANCELLED (1), message 10 chars, 44 ms
  reason 2000 chars   CANCELLED (1), message 1024 chars, 49 ms
```

## Canary

The ablation is the canary: the 809 site's cap removed in place
(`1 > 0 ? null : ...`) changes the text, not the status, so the cap there is
cosmetic (that send passes no validating hop). Restored.

## The verdict questions

1. Only the cap (or the reason's length) differs.
2. Yes: the text length follows the cap.
3. At the caller.
4. Three caps, two reason lengths.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. Client policy left at defaults, so only the server's cap is under test.
A2. n/a. L1. n/a.

## Gate

No code changed; the ablation was reverted, the probes are outside the tree.

## Siblings

No code changed. The sweep covered core, websocket, http, isolate and
http2; websocket, http and isolate build no trailer of their own.

## Not fixed

none.

## Links

Lens `../lenses/RPC-02-refusal-trailer-violates-policy.md`.
