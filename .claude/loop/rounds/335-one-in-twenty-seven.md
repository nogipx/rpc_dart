---
round: 335
verdict: CLEAN
packages: [rpc_dart, rpc_dart_isolate, rpc_dart_http2]
lens: RPC-04
bench: none
commit: yes
---

# Round 335 — one in twenty-seven

## Target

The detector round 334 produced, run over the corpus it came from. Rounds 331
and 332 established that a criterion invented on one instance is a guess about a
class until it is pointed somewhere else; this is that, for RPC-04's new
question — *does every branch that constructs this collaborator pass the same
arguments?*

## Hypothesis

`UnaryCaller` will not be alone. A logger or a policy is optional at most of
these constructors, the analyzer says nothing about an argument nobody passed,
and the pipelines construct the same classes from two branches in several
places.

## Before

Every class in core and transport constructed in more than one place:

```
class                     sites   verdict
CallProcessor               4     consistent
stream responders (7 kinds) 8     all pass `logger: contextLogger`
stream callers              4     ONE omission -> round 334; other three agree
RpcMessageParser            3     two expression differences, both benign
RpcChannelTransport         8     all pass `policy:`
                           ---
                            27    1 defect, already fixed
```

## Mechanism

The hypothesis is wrong and the corpus is clean. Worth keeping is WHY the two
near-misses are not defects, because a textual comparison would flag both:

**`maxBufferedBytes`** — core passes `policy.effectiveMaxBufferedBytes`, http2
passes the raw nullable `_policy.maxBufferedBytes`. Different expressions,
identical results: the parser's own fallback is
`maxBufferedBytes ?? (maxMessageLength + prefix)` and
`effectiveMaxBufferedBytes` is `maxBufferedBytes ?? (maxMessageLengthBytes +
prefix)`, with `maxMessageLength` set from `policy.maxMessageLengthBytes` at
every site. The fallback is written twice and agrees — which is RPC-25's
"identical copies can both be wrong" inverted: different copies, both right.

**`decompressor`** — core passes one, http2's per-stream parsers pass none.
Deliberate: with no decompressor the parser re-encodes the frame with the
compression bit set and passes it up, so the ENDPOINT's parser decompresses. A
transport parser that decompressed would do it twice.

## After

No change. `../checked/C-36-construction-argument-parity.md` records the 27
sites and the two near-misses, so the next sweep does not re-open them.

## Canary

n/a — nothing fixed. The detector's sensitivity is not assumed: **round 334 is
the control.** The same reading over the same corpus one round earlier found a
real defect whose symptom had been invisible since the class was written. A
sweep that returns 1 in 27 with that provenance is a measurement; the same sweep
with no prior find would be hope.

## Gate

No code changed; `git status` clean apart from the journal. Last full gate at
round 334: analyze clean over 21 packages plus `rpc_dart_wasm`, `format:check`
clean, `test:unit` 14 packages 0 failures.

## Not fixed

Nothing to fix.

The check does not generalise to a script. Two of 27 sites differ textually and
neither is a defect, so a mechanical diff of argument names would have a 2/3
false-positive rate on its findings — which is why C-36 records the reasoning
rather than a regex.

## Links

RPC-04 (`applied:` gains 335). C-36 new.

What this adds: the detector is worth running when a class GAINS an optional
parameter, not on a schedule. All 27 sites were correct except the one a round
had just fixed, and the surface only changes when a constructor does.
