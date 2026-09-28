---
round: 468
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-25
bench: P-117 — new
commit: yes
---

# Round 468 — the third home has no door

## Target

B-89, open since round 450 with no owner decision — filed after the backlog
review, so it is mine to take from the state. It names three homes for the
stream-id parity rule, says plainly that nothing has been shown to bite, and
attaches two questions that decide whether anything does.

## Hypothesis

The lead's own: if the responder has no entry point for a watermark, its `2` is
unreachable state and there is nothing to align — and if the proxy never carries
an even value, the caller's rule never disagrees with core's.

## Before

Question 1 is answered by one line, and it is the `implements` clause:

```
RpcHttp2ResponderTransport implements
    IRpcTransport, IRpcSecurityPolicyAware, IRpcFlowControlled
```

**Not `IRpcStreamIdSequence`.** No `resumeStreamIdsAfter`, no
`lastIssuedStreamId`; `_nextStreamId = 2` is written once and only incremented.
So there is no door: nothing can hand it a wrong-parity value. It is not a third
implementation of a rule, it is an initialiser with no rule attached — and the
lead said so conditionally, which is what made the check cheap.

Question 2, measured at two levels (P-117):

```
resumeStreamIdsAfter, driven directly
  watermark=  2 (even)  -> 5, 7     both ODD
  watermark=  8 (even)  -> 11, 13   both ODD
  watermark=100 (even)  -> 103, 105 both ODD

through RpcClientConnection, three swaps
  ids = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
  even ids = NONE   strictly increasing = true
```

## Mechanism

None. No code changed.

## After

Unchanged. The output is the negative, C-54, and the `## Ask` answered.

## Control — which measured more than it was aimed at

`final aligned = streamId;`, the alignment deleted:

```
watermark=  2 (even)  -> 4, 6     PARITY BROKEN
watermark=  8 (even)  -> 10, 12   PARITY BROKEN
watermark=100 (even)  -> 102, 104 PARITY BROKEN
```

The bench sees a break, so a clean row is about the code.

**And the proxy arm stayed CLEAN under that same ablation** — still all odd. That
is a stronger statement than the unablated run: the alignment is not merely
correct on that path, it is never exercised on it, because `lastIssuedStreamId`
is `_nextStreamId - 2` and odd by construction. Second round running where an
ablation aimed at one arm answered a question about another.

## The `## Ask`, answered

If the three were one, whose behaviour? **Not the manager's.**
`RpcStreamIdManager` also computes a max-assignable bound and tracks release, and
http2 delegates real id assignment to `package:http2`'s `makeRequest` — its
`_nextStreamId` is rpc_dart's own handle, not a wire id. Adopting the manager
would put a bound and a release ledger on a transport that needs neither, for a
rule four tokens long with no reachable disagreement.

## Canary

None — nothing was fixed. The control above is this round's variation and it
turns three rows red on command.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages. No source changed, so the
gate's job here is to confirm the control was restored rather than left in.

## Not fixed

**Nothing, and that is the verdict.** What remains true and is worth stating: the
http2 caller's alignment is reachable only from the PUBLIC transport surface — a
third party calling `resumeStreamIdsAfter` with an even value. Not dead code, and
not something this library can reach.

**The websocket transport was not driven.** It uses `RpcStreamIdManager`, so it
is the rule's first home rather than a fourth, and round 465 already measured its
ids across a reconnect.

## Links

- RPC-25 — "What a no-drift candidate earns: nothing", and 451's rule about which
  layer owns a duty
- C-49 — the sweep whose false "already shared" produced this lead
- Round 360 — gave `RpcStreamIdManager` one home for the alignment, which is the
  first of the three
- P-117, C-54, B-89
