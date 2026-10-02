---
round: 648
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: none — the witness test is the measurement; the coverage-review probe is cov_core_client_connection.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 648 — two connect loops

## Target

A coverage-review finding (round 640): `RpcClientConnection._onTransportDropped`
while a connect loop is already running.

## Hypothesis

A connection runs one connect loop at a time, as the guard in
`_connectWithBackoff` says.

## Before

```
factory takes 100 ms; connect() while online, live transport drops 20 ms later
factory calls 3   open [2]   states Connecting, Online | Connecting, Offline, Connecting, Online, Online
```

## Control

`connect()` while online, no drop: factory calls 2, one open, Online once more.

## Mechanism

RPC-21, a lifecycle API driven while another is in flight. `connect()` while
online -- the documented app-resume or retry-button case -- starts a loop with
the live transport still attached. When that transport dropped, the drop
handler set `_connectingGuard = null` before calling `_connectWithBackoff`, so
the guard let a second loop start beside the first. Both built a transport;
the first to attach was retired by the second. The reset dates from the
class's first commit with no recorded reason; every loop exit completes the
guard, so nothing needs it.

## After

The reset is gone: a drop during a running loop leaves that loop to finish.
Factory calls 2, one open, Online once. A drop with no loop running still
reconnects (GUARD arm).

## Canary

The reset restored: 3 transports built.

## Gate

Recorded in round 650.

## Not fixed

Nothing is orphaned either way -- `attach` closes the previous transport -- so
the cost was a duplicate reconnect and calls dying on the first replacement.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 648]`.
Test `packages/core/rpc_dart/test/resilience/a_drop_during_a_connect_starts_no_second_loop_test.dart`.
