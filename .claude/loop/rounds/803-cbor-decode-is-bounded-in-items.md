---
round: 803
verdict: FIXED
packages: [rpc_dart]
lens: RPC-27
bench: P-278 — reused
commit: yes
severity: S1
release: breaking
---

# Round 803 — cbor decode is bounded in items

## Target

B-275, the owner's decision of 2026-10-10 (option 2): an item budget on the
CBOR decoder as an `RpcSecurityPolicy` field that reaches the codec, default
about 1 Mi items. First of the five decided leads `next` listed, and the S1
among them: invariant I-8 is NOT ENFORCED and waits on it.

The class, counted before the fix: one decoder (`_FastCborReader`), reached
from `CborCodec.decode` and `decodeUnsafe`. Peer bytes reach it from four
sites in core: `UnaryResponder.handleMessage`, the stream responder's
`_processDataMessage`, `UnaryCaller.call` and the stream caller's
`_processResponseData`. Generated codecs call `CborCodec.decode` and
`decodeUnsafe` directly as tear-offs inside an `RpcBinaryCodec`, so an
argument on `IRpcCodec.deserialize` would miss them; the budget therefore
travels in a scope around the synchronous decode (`withCborItemBudget`).

## Hypothesis

A message within `maxMessageLengthBytes` decodes to tens of heap bytes per
wire byte, before any interceptor, because nothing bounds what it decodes to.

## Before

P-278 at f979f886, re-run (the control first):

```
  arm               on the wire   max rss    took      answer
  bytes (control)   16383 KiB     +49 MiB    76 ms     UNAUTHENTICATED
  emptyMaps         16383 KiB     +1128 MiB  1265 ms   UNAUTHENTICATED
```

## Mechanism

`_FastCborReader` bounds nesting (`_maxDepth`) and nothing else: an empty map
is one byte on the wire and a `LinkedHashMap` on the heap. The request is
decoded before the interceptor chain (which receives the decoded `TRequest`),
so an authentication interceptor runs after the cost.

## Fix

`_FastCborReader` charges one item per value, per map key and for the top
map, and throws `CborItemLimitException` (a `FormatException`) past its
budget. `CborCodec.decode` / `decodeUnsafe` take `maxItems`; without it the
budget is the one `withCborItemBudget` put in force, else
`CborCodec.defaultMaxItems` (1 Mi). `RpcSecurityPolicy.maxDecodedItems`
(default the same, in `toMap` / `fromMap`) is applied at the four sites by
`_decodePeerMessage`, which turns the refusal into
`RpcPeerFaultException(RESOURCE_EXHAUSTED)`; both responder sites now pass a
peer fault through instead of rewrapping it as INTERNAL. The shipped skill's
policy table and codec table name the field and the argument.

## After

```
  arm               on the wire   max rss    took      answer
  bytes (control)   16383 KiB     +49 MiB    77 ms     UNAUTHENTICATED
  emptyMaps         16383 KiB     +96 MiB    138 ms    RESOURCE_EXHAUSTED
  emptyMaps, gzip   15 KiB        +105 MiB   163 ms    RESOURCE_EXHAUSTED
```

The witness is the matrix row `i8_decode_is_bounded_test.dart`: four call
shapes x five members, a request past a 1000-item budget refused
RESOURCE_EXHAUSTED with no `received` at the handler and exactly 1000 items
delivered whole; the same for a response at the caller; and a request of
twice the default refused under the default policy. 45 passed, 9 wasm
skipped (outside the workspace).

Cost (P-294, asked and accepted by the owner before the commit): +0.5% per
decode of a 10- or 100-field map, +2.5% for a list of 10000 ints.

## Canary

Five, one per half, each switched off in place and restored:

1. The count (`_countItem` returns at once): all 45 cells fail, `Expected:
   <8> Actual: <0>`.
2. The policy (`_decodePeerMessage` passes `CborCodec.defaultMaxItems`): the
   40 small-budget cells fail `Expected: <8> Actual: <0>`; the 5
   default-policy cells pass.
3. The status (the `CborItemLimitException` is rethrown unmapped): all 45
   fail `Expected: <8> Actual: <13>`.
4. The unary responder's `on RpcPeerFaultException { rethrow; }` removed:
   exactly the 10 unary request cells fail `Expected: <8> Actual: <13>`.
5. The stream responder's `e is RpcPeerFaultException ? e` disabled: exactly
   the 15 streaming request cells fail `Expected: <8> Actual: <13>`.

Restored: 45 passed.

## The verdict questions

1. Yes: `bytes` and `emptyMaps` have the same wire size, path and refusal;
   only the item count differs.
2. Yes: +49 MiB / 76 ms against +1128 MiB / 1265 ms.
3. On the responder's process (`ProcessInfo.maxRss` after the call) and its
   answer status; the matrix counts `received` at the handler.
4. The bound is read as a refusal status and the absence of `received`,
   with the paired call at exactly the budget showing the handler does
   report.
5. Yes, quoted in `## Canary`.
6. Five halves, five canaries; each failed a different, predicted set.
7. From the numbers.
8. No target dismissed. B-273, B-274, B-276 and B-280 are decided and left
   for the next rounds; B-281, B-283 rank lower than this S1.
9. none.
10. Siblings below are rows of the same matrix, run on each member.
A1. The matrix's rigs build the server's policy (`serverPolicy`) and the
    caller's (`rig.caller(policy:)`) as separate objects; on isolate one
    policy is shared by design, and the rows set it from whichever side is
    under test.
A2. Volume.
L1. Yes: the refusal message names the budget (`CBOR data decodes to more
    than 1000 items`), and the paired call at the budget succeeds.

## Gate

`melos run analyze`, `test:unit` (16 suites, conformance +500 ~148),
`format:check`, `license:check`, `check:skills`; `test:web` (15 suites) and
`test:wasm` (53) for the core change: green.

## Siblings

- unary: fixed here (`UnaryCaller`, `UnaryResponder`); the matrix's unary
  rows pass on five members
- client: fixed here through the shared stream processors; clientStream
  rows pass
- server: fixed here through the shared stream processors; serverStream rows
  pass
- bidirectional: fixed here through the shared stream processors; bidi rows
  pass
- caller: fixed here; the response rows fail with the fix off and pass with
  it on
- responder: fixed here; the request rows fail with the fix off and pass
  with it on

## Not fixed

- The default still lets one call cost about 100 MiB and 140 ms (and 15 KiB
  of gzip buys that). That is the owner's chosen default; a lower one is
  theirs.
- `invariants/I-8` still reads `across: —`, `test: —`. The test exists now
  (`packages/test/rpc_dart_conformance/test/i8_decode_is_bounded_test.dart`);
  setting the invariant's fields is the owner's.
- A codec that catches the `FormatException` and throws its own type loses
  the RESOURCE_EXHAUSTED mapping and is answered INTERNAL; the bound still
  holds.
- The caller logs a refused response at error level per message (the
  existing "Failed to deserialize response" path); a hostile server chooses
  how many.
- The web was not measured for cost.

CHANGELOG line (breaking): "`RpcSecurityPolicy.maxDecodedItems` (default
1048576) bounds the CBOR items one inbound message decodes to, in both
directions, generated codecs included; past it the call fails
RESOURCE_EXHAUSTED. A message that decoded before may now be refused: raise
the field on an endpoint that receives larger lists. `CborCodec.decode` and
`decodeUnsafe` take `maxItems` and apply `CborCodec.defaultMaxItems` by
default."

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`. Benches
`../probes/P-278-cbor-decode-cost-per-wire-byte.md`,
`../probes/P-294-what-the-item-budget-costs-a-decode.md`. Lead
`../backlog/B-275-the-cbor-decoder-has-no-item-budget.md`, closed.
