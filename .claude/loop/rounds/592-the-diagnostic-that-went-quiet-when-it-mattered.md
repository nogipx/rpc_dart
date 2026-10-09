---
round: 592
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-19
bench: none — the lead forbids starting with a reproduction under load and prescribes reading the assembly instead; both halves are witnessed by ablation
budget: probes 0/5, canaries 1/5
commit: yes
release: changelog
severity: S3
---

# Round 592 — the diagnostic that went quiet when it mattered

## Target

`B-219` — `health().details['peerStreamIds']` answered null under load, where the
same call three seconds earlier returned 0.

The lead's own instruction, followed: *"Do not start by looping the gate: one
reproduction under load costs minutes and says nothing a reading of the assembly
does not say faster."*

Lens RPC-19: one signal with two meanings — here `details`, which carries the
wrapper's counters on one answer and not on the others.

## Hypothesis

The key cannot be absent from the assembly at line 613 — it is set unconditionally
after the spread. So `health()` returned from somewhere else.

## Before

It does, from two early returns above it:

```
_closed        RpcHealthStatus.closed(...)                       no details at all
_disconnected  RpcHealthStatus.degraded(details: {'supported': true})   no counters
```

So `details['peerStreamIds']` is null exactly while the transport is closed or a
reconnect is down — and that is reachable in this test without touching it: the
app-level heartbeat closes the socket when a pong misses its one-interval deadline,
which on a loaded machine is what happened. `load average 9.62` is in the lead.

## Mechanism

The two early returns exist for good reasons, both documented: a closed transport
must not delegate, and `_inner` is already closed during a reconnect so delegating
made the wrapper contradict itself. Neither reason says anything about the
wrapper's own counters, which are the only thing in `details` that no inner health
can see — so they were dropped by omission on exactly the two answers a supervisor
polls `health()` to get.

## After

The counters are assembled once and present on all three answers:

```dart
Map<String, Object> get _ownDetails => {
  'idsOnThisConnection': _idsOnThisConnection.length,
  'peerStreamIds': _peerStreamIds.length,
};
```

The degraded branch keeps its own `supported: true` and gains the counters, so the
change adds rather than swaps.

## Canary

```
the counters removed from the two early returns
  the counters survive every answer health() can give
    Expected: <Instance of 'int'>
      Actual: <null>
    the disconnected answer: RpcHealthLevel.degraded {supported: true}
```

The message names the state, which is what the original crash could not: round
555's gate reported `Null check operator used on a null value` and a line number.

## The test's `!` was the lead's other half, and it is gone

`_peerIds` was `details['peerStreamIds']! as int`. It is now an `expect` that prints
the level, the message and the whole `details` map on failure. The five existing arms
are unchanged otherwise.

That half is a READING, not a measurement: the better message only appears in the
state that needs load to reach, and this round deliberately did not chase load.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_websocket +242
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2237 / 2237, REUSE compliant
```

## Not fixed

**`_reconnectOnce` has three more `RpcHealthStatus` returns without the counters**
and they are left alone: that is `reconnect()`'s result, which reports what happened
to an ATTEMPT, and `supported: false` is its own vocabulary. Nothing reads counters
off it, and adding them would be scope with no claim behind it.

**No arm reproduces the original crash under load.** The lead forbade starting there
and the reading was enough to find the mechanism; what is pinned is that the key
survives both states, driven deliberately.

**The responder and peer transports were not read.** The grep for
`RpcHealthStatus.closed(|degraded(` in this package returns only this file, so there
is no sibling with the same shape here — but the question has not been asked of the
other transports' wrappers.

## Links

Lead `../backlog/B-219-a-health-detail-went-missing-under-load.md` — CLOSED.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [592]`.
Round `555` — whose gate reported it.
