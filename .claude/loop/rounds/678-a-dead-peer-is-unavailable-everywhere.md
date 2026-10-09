---
round: 678
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_isolate]
lens: RPC-19
bench: none — the parity matrix filed with the lead (`.dart_tool/probe/parity_matrix.dart`, row 6.call-after-peer-dead), re-run, plus a witness for the isolate case the matrix does not drive
commit: yes
release: changelog
severity: S2
---

# Round 678 — a dead peer is UNAVAILABLE everywhere

## Target

B-252, core and websocket, decided by the owner: a call after the PEER died is
UNAVAILABLE on every transport; a call after this side's own `close()` stays
FAILED_PRECONDITION. Two sites: `RpcChannelTransport` (memory, isolate,
websocket's inner channel, wasm) and `RpcNoConnectionException` (websocket,
http2 and `RpcClientConnection` with no live connection).

## Hypothesis

`RpcClosedException` is 9 whoever closed the transport, and
`RpcNoConnectionException` is 9 unless a reconnect is in flight.

## Before

```
6.call-after-peer-dead
  memory     RpcClosedException/9        "Transport is closed"
  isolate    RpcClosedException/9        "Transport is closed"
  websocket  RpcNoConnectionException/9  "... call reconnect() ..."
  http1/http2  14
```

## Mechanism

`RpcChannelTransport` closes itself when its channel ends and then refuses with
the same `RpcClosedException` as after a local `close()`;
`RpcNoConnectionException` chose 9 for "no reconnect running".

## Fix

- `RpcClosedException.byPeer(what)`: UNAVAILABLE, `byPeer: true`. The channel
  transport sets `_closedByPeer` when its channel ends under it and refuses with
  that from then on. `close()` by this side is unchanged, 9.
- `RpcNoConnectionException` is UNAVAILABLE in both states; `reconnecting` and
  the message still say which.

## After

```
6.call-after-peer-dead
  memory     RpcClosedException/14  "Transport is closed: the peer went away"
  isolate    RpcClosedException/9   (the matrix's isolate "kill" is the host's own
                                     kill(), which closes the transport itself)
  websocket  RpcNoConnectionException/14
  http1/http2  14
6.call-after-caller-close   9 on all five, unchanged
```

The matrix's isolate arm is this side closing, so 9 is the decided answer
there. A worker that exits BY ITSELF is the peer dying, and is driven by the
witness: 14.

## Canary

`packages/transport/rpc_dart_isolate/test/a_call_after_the_worker_died_is_unavailable_test.dart`,
`_closedByPeer` never set: both the worker-exit and the in-memory peer-close
arms red, `Expected: <14> Actual: <9>`. The GUARD (own close stays 9) green both
ways. Restored: 3 of 3 green.

`a_failed_reconnect_is_not_a_running_one_test` pinned 9 for a failed websocket
reconnect -- the behaviour decided away -- and now pins 14 with
`reconnecting: false`.

## The verdict questions

1. Yes: the flag alone; the GUARD is the own-close control.
2. Yes: 9 against 14.
3. Yes: the status the caller got.
4. Not zero-valued.
5. Yes, quoted.
6. Two sites. The channel one has the canary; the `RpcNoConnectionException`
   one is a constant whose test reads 14 and read 9 before.
7. Yes; the owner's decision.
8. None.

## Gate

`analyze`, `test:unit` (15 packages), `format:check`, `license:check` green.

## Not fixed

Nothing on B-252.

## Links

Lead `../backlog/B-252-a-dead-peer-is-9-on-three-transports-and-14-on-two.md` closed.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 678]`.
