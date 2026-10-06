---
round: 661
verdict: FIXED
packages: [rpc_dart]
lens: RPC-03
bench: P-228 — new
commit: yes
release: changelog
---

# Round 661 — the watermark after the wrap

## Target

B-243, a measured defect with a named fix and no owner question. Scope: every
place a continuation cursor is computed -- `RpcStreamIdManager.lastIssuedId`
(core channel transport, HTTP/1.1 caller), the `RpcClientConnection` proxy's
watermark, the websocket caller's own reconnect (reads the latest cursor
already), and the http2 caller's counter (http2 cannot issue past 2^31-1 on one
connection, so it never wraps). Two sites change.

## Hypothesis

After a wrap the proxy's max-watermark seeds the next transport at the top of the
space, which restarts it at 1; with a stream held across the wrap, the manager's
cursor is pinned at the top while it recycles, which does the same.

## Before

```
A2 wrap, long-lived   cursor ... 2147483647, 2147483647, 2147483647
B WITNESS near top    conn1 [2147483643, 2147483645, 2147483647, 1, 3]
                      conn2 [2147483643, 2147483645, 2147483647, 1, 3]   overlap 5
B CONTROL low         conn1 [1003..1011]  conn2 [1013..1021]             overlap 0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/lim_ids.dart` (P-228).

## Mechanism

The proxy kept the highest cursor it had ever seen, so a transport that wrapped
never lowered it, and the next one was seeded at the top. Separately the manager
reported its sequential cursor, which stays at the maximum while recycling, not
the id it actually handed out.

## After

```
A2 wrap, long-lived   cursor ... 2147483647, 1, 1, 1
B WITNESS near top    conn2 [5, 7, 9, 11, 13]   overlap 0
B CONTROL low         unchanged, overlap 0
```

The manager tracks the id most recently issued, recycled ones included, and
`lastIssuedId` returns it. The proxy keeps the latest transport's cursor instead
of the max, and reads the live one directly; each transport is seeded from the
previous, so its cursor is behind the old watermark only after a wrap.

## Canary

Two halves, two canaries, each failing only its own witness:
- proxy max restored: `a swap does not replay the ids issued before it` failed
  with `Expected: empty Actual: Set:[2147483643, 2147483645, 2147483647, 1, 3]`;
- manager returning `_lastId`: `a manager resumed from a recycling one continues
  after it` failed with `Expected: not <1> Actual: <1>`.

The GUARD (below the top, the sequence still continues) green both ways. Restored:
green.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart +2055 ~1); `format:check` clean; `license:check` compliant. The id test
file on `-p node`: +12.

## Not fixed

Nothing in scope. A new transport continues after the old one's last id, so it
reaches an id the old one still holds only after another ~2^30 calls.

## Links

Lead `../backlog/B-243-stream-ids-collide-across-reconnects-after-a-wrap.md` closed.
Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` -- `applied: [..., 661]`.
Bench `../probes/P-228-stream-ids-across-the-wrap.md`.
Test `packages/core/rpc_dart/test/resilience/client_connection_stream_ids_test.dart`.
