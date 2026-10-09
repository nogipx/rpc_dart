---
round: 732
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: P-243 — new
commit: yes
release: changelog
severity: S2
---

# Round 732 — concurrent endpoint closes share one

## Target

Round 722's question asked of the most-used teardown in the library:
`RpcEndpointBase.close()` and its three overrides (caller, responder, peer),
driven twice at once.

## Hypothesis

The overrides read `isActive`, then await their own pipeline release before
`super.close()` clears the flag. Two concurrent calls both release the
pipeline, and the second returns from `super.close()` at once, while the
transport is still closing.

## Before

Probe: `packages/core/rpc_dart/.dart_tool/probe/r732_second_close_returns_early.dart`.
A caller endpoint over a transport whose `close()` takes 200 ms, closed twice
concurrently.

```
  first close returned at 210 ms; second at 6 ms, transport closed by then: false
```

## Mechanism

As hypothesised. The overrides did `if (!isActive) return; ... await;
super.close()`, and the base set `_isActive = false` only after that await.

## Fix

`close()` is the base's alone: `_closing ??= _closeOnce()`, which every
concurrent and later call shares. The subclasses override a library-private
`_closeResources()` instead of `close()`. All endpoints are parts of one
library, so no public surface changes. No endpoint subclass exists outside
it (grep across packages).

## After

```
  first close returned at 209 ms; second at 209 ms, transport closed by then: true
```

## Canary

`close()` without the sharing: `a second close() returns only once the
transport is closed` fails with "the endpoint closed twice" (`Expected: <1>,
Actual: <2>`). The witness asserts both halves, the early return and the
single close. The first canary, which checked only the early return, passed:
the new structure without the shared future waits, but closes twice. The
witness was extended before the record was written.

## The verdict questions

1. Yes: one endpoint, two concurrent calls.
2. Yes: 6 ms with the transport open against 209 ms with it closed.
3. In the transport's own close.
4. n/a.
5. Quoted.
6. One mechanism, two observables, both asserted.
7. Not a trade.
8. None.
A1. n/a.
A2. Latency: a slow transport close.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. rpc_dart suite: 2100.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 732]`.
New bench `../probes/P-243-a-second-endpoint-close.md`.
