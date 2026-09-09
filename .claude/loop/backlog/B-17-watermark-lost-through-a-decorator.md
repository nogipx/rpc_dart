---
status: closed (round 224)
round: 217
commit: 576f1815
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart
reason: decided by owner (round 223) — refuse the transport at attach; ready to implement, data loss, ranks first
---

# B-17 — a decorator erases the stream-id watermark, and a live call dies

> **Closed by round 224.** Such a transport is refused at attach, so the
> collision cannot happen. P-09's decorated arm went `handlers ended 1 -> 0`,
> the control unchanged at `0 -> 0`. The compile-time version of the same
> requirement is `B-21-reconnectable-transport-type.md`.

`RpcClientConnection` carries a stream-id watermark across transport swaps so a
replacement cannot hand out an id a dead call still holds. Both hops guard on
`is IRpcStreamIdSequence` and return silently when it is absent, so an
application decorator that forwards every `IRpcTransport` member and declares
nothing else erases the whole mechanism.

Measured (P-09), with the factory returning a plain decorator instead of the
transport:

    factory returns          id before   id after   handlers ended
    the transport itself         1           3          0 -> 0
    a plain decorator            1           1          0 -> 1

The last column is the defect: a live bidirectional call's request stream was
half-closed by an unrelated dead call's teardown, and the server finished
serving it. Silent, and it is the exact scenario the watermark exists for.

Round 209 found the same class on http2 with `IRpcFlowControlled`, and the fix
there was `_preserveCapabilities`. **That is not available here**: http2 wraps a
decorator around a transport it still holds, whereas this factory returns the
decorator with the real transport hidden inside it. There is nothing to fall
back to.

## Round 218: the chosen fix was tried and CANNOT work

Generation-tagging was implemented in full — a counter bumped at every
`attach`, a ledger written in `createStream`, a staleness guard on all seven
stream-scoped forwards — and P-09 did not move: still `0 -> 1`.

Not an implementation bug. When the ids genuinely collide the new call is issued
**the same integer**, so remembering it at the new generation overwrites the
dead call's entry and the stale `finishSending(1)` looks current. Refusing to
overwrite drops the LIVE call's own half-close instead, which is what the guard
"a half-close on the CURRENT transport is still sent" exists to catch.

**An `int` does not carry enough to tell the dead caller's id 1 from the live
caller's id 1.** Anything keyed on the id alone has this hole. The watermark
works only because it stops the collision happening at all.

The warning half was implemented too and never fired: the callback is wired
after the first attach, so the branch ran with it null. Fixable, but a
diagnostic nobody has seen fire is not worth shipping on the strength of
reading it. Everything was reverted; the tree is at HEAD.

## A third candidate, which would work

**Id translation.** The proxy hands out ids from its OWN monotonic sequence and
keeps proxy-id -> (generation, inner-id), translating on every stream-scoped
call and on every inbound message's `streamId`. A retired proxy-id has no live
mapping, so dropping it is unambiguous, and the new call gets a different
proxy-id even when the inner reuses 1. Capability-independent and correct.

Cost: a full translation layer over the transport interface, inbound direction
included. Materially bigger than what was authorised, so it is not something to
start without saying so.

## The two candidates

1. **Generation-tag the ids.** The proxy issues every id through
   `createStream()`, so it can record which transport generation each belongs to
   and drop stream-scoped operations for ids from a retired one.
   Capability-independent, so it also covers a stale id used when the watermark
   WAS carried.
   Cost: a stale `finishSending` becomes a silent no-op rather than reaching
   anything, and it adds a per-id map on the hot path — bounded by our own
   traffic, pruned on release.

2. **Refuse the transport at attach.** If the factory returns something that is
   not `IRpcStreamIdSequence`, fail loudly instead of connecting.
   Cost: an application with a decorator that works today stops connecting at
   all. Breaking, but impossible to get silently wrong.

Warning and carrying on is not a candidate: it leaves the data loss in place,
and the config's bar rules out diagnostics as a round's product.

## Owner decision

> **Round 217's decision (tag + warn) was measured unimplementable in round 218
> and is superseded.** It is preserved at the bottom of this file so the reason
> is not lost. Nothing from it shipped.

**Refuse the transport at attach.** (Asked and answered in round 223.)

If the factory's transport does not implement `IRpcStreamIdSequence`, fail
loudly instead of connecting. Airtight, and impossible to get silently wrong.

### The fact that makes it safe

Checked at 0e7b984a — **every first-party caller transport already implements
the capability**, so the refusal breaks no supported path:

    isolate, native and web   returns a bare RpcChannelTransport
                              (channel_transport.dart:36 implements it)
    wasm                      RpcChannelTransport.fromChannel
    websocket                 websocket_caller_transport.dart:32, declares it
                              and forwards to its inner RpcChannelTransport
    http2                     rpc_http2_caller_transport.dart:38
    http                      rpc_http_caller_transport.dart:136

The refusal therefore fires for exactly one population: hand-written decorators
and mocks. That population is not "working today" — it is silently half-closing
live calls on every reconnect, which is what P-09's `0 -> 1` row is. The break
makes an existing silent failure visible, and the user-side remedy is two
members forwarded.

### Notes for the round that carries this out

- Check on **every** `attach`, including the first. Refusing only on the
  reconnect path would hide the error until it happens in production; refusing
  at first connect surfaces it on the developer's first run.
- The error must name the class, the missing interface and the two members
  (`resumeStreamIdsAfter`, `lastIssuedStreamId`). A bare type error teaches
  nothing.
- **No opt-out flag.** Adding a switch pre-emptively for a legitimate case
  nobody has reported is speculative, and a default that hides the hole is how
  this defect got here.
- P-09 is the witness: its second row must stop reading `0 -> 1` — by throwing,
  not by passing. Expect to rewrite the probe's decorator arm to assert the
  throw.
- **Most of the diff is tests, not lib.** Files using `RpcClientConnection` with
  hand-rolled fakes: 8 in `packages/core/rpc_dart/test/resilience/`, plus
  `rpc_dart_http2/test/reconnect_close_race_test.dart`,
  `rpc_dart_websocket/test/reconnect_close_race_test.dart`,
  `rpc_dart_http/test/stream_ids_survive_swap_test.dart` and
  `rpc_dart_log/test/reconnect_test.dart`. Each fake transport needs the
  capability declared. Mechanical, but budget for it.
- Watch the GUARDs in `client_connection_stream_ids_test.dart` — "calls still
  run across repeated swaps" and "a half-close on the CURRENT transport is still
  sent" — and `rpc_dart_framework/lib/src/rpc_app.dart`, which also builds one.
- This is a **breaking change** for anyone with a decorator: a major bump, and a
  CHANGELOG entry that states the remedy rather than just the break.

### The follow-up this deliberately does NOT do

The honest end state is compile-time, not runtime: an
`IRpcReconnectableTransport implements IRpcTransport, IRpcStreamIdSequence` as
the factory's return type, so a decorator author gets a red squiggle instead of
a runtime exception. That is a bigger, separate breaking signature change and is
not authorised here — file it as its own lead for the next major rather than
smuggle it into this fix.

## Superseded — round 217's decision, kept for the record

**Both: tag, and warn on attach.** Generation-tag the ids so the data loss is
gone regardless of the capability, AND log a warning at attach when the
factory's transport does not implement `IRpcStreamIdSequence`. Round 218
implemented both in full: the tag could not work (an `int` cannot distinguish
the dead caller's id 1 from the live caller's id 1 — see above) and the warning
never fired (the callback is wired after the first attach). Everything reverted.
