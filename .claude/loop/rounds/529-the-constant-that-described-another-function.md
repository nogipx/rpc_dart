---
round: 529
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-23
bench: none — a witness and three controls, no numbers to compare
commit: yes
---

# Round 529 — the constant that described another function

## Target

B-133, next in rank order: `pingInterval` does nothing when the transport is constructed
directly on the VM.

Lens RPC-23 again, and this time the narrative is a NAME plus its doc.
`platformHonoursPingInterval` is documented "Whether THIS platform's `openWebSocket`
actually applies `pingInterval`" — a statement scoped to one function, read by a
constructor that never calls it.

## Hypothesis

On the VM the constant is true, so the app-level heartbeat is off; only `connect()` puts the
interval on the dart:io socket; so a caller who builds the channel and passes `pingInterval:`
gets no keepalive at all.

## Before

The witness — a hand-built `IOWebSocketChannel`, `pingInterval: 200ms`, against a peer that
completes the upgrade and then answers no RPC — never notices:

```
  hand-built channel, pingInterval: 200ms      never noticed (capped at 5s)
```

CONFIRMED. Both keepalives are off: dart:io was never told the interval, and the app-level
heartbeat was skipped on the strength of a constant whose premise does not hold on this path.

## Mechanism

`openWebSocket` is the only thing that sets `webSocket.pingInterval`, and only `connect()`
calls it. The constructor consults `platformHonoursPingInterval` anyway.

**And the sketch in the lead cannot be implemented.** "Apply the interval to the passed
socket when it is a dart:io `WebSocket`" needs the socket, and
`IOWebSocketChannel`/`AdapterWebSocketChannel` keep it private — there is no accessor.
So the constructor can neither set a native ping nor ask whether one is running.

## After

The constructor defaults to "nobody is pinging this socket", which is all it can know, and
`connect()` passes `platformHonoursPingInterval` explicitly — the one call site where the
constant describes what happened. `platformHandlesPing` stops being a test hook and becomes
the way a caller who built the socket with a native ping says so.

```
  hand-built, pingInterval: 200ms              noticed
  CONTROL hand-built, no interval              never
  CONTROL hand-built, platformHandlesPing:true never
  CONTROL connect(), pingInterval: 200ms       still healthy after 2s
```

The last control is what bounds the fix: `connect()` must NOT gain a second keepalive.

## Canary

Default put back to `platformHandlesPing ?? platformHonoursPingInterval`: the witness fails
`Expected: not null / Actual: <null>`. All three controls pass in that state, which is what
says the witness reads the default and not the rig.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package:
218 passed.

## Not fixed

**A control was wrong first, and the reason is worth keeping.** The first version asserted
that `connect()` on the VM notices this peer via the native ping. It does not, and the peer
is why: **a dart:io `WebSocket` answers a ping frame itself**, before any listener sees it,
so a server that answers no RPC is still a LIVE path for a native keepalive. The arm as
written would have failed the fix for a reason unrelated to it. Rewritten to assert the
invariant that actually matters — `connect()` does not add a second probe — where the same
asymmetry makes the check sharp.

**No real half-open path was built.** Detecting one natively needs a peer that stops
pongging, which means a TCP-level black hole rather than a silent server. Nothing here
measured the native ping's own detection time.

**The doubling case is accepted, not measured.** A caller who builds
`IOWebSocketChannel.connect(url, pingInterval: x)` and also passes `pingInterval: x` here now
runs two keepalives. They can say `platformHandlesPing: true`, and the doc says so, but the
default favours "a keepalive exists" over "exactly one keepalive exists".

**Behaviour change on a published package**: a direct construction with `pingInterval` now
runs an RPC-level probe on the VM where it previously ran nothing. Wants a CHANGELOG line.

## Links

Lens RPC-23. No bench — the evidence is a witness and three controls, with nothing to compare
across rounds. Lead B-133 closed. Round 466 built the app-level heartbeat this fix now
reaches; its tests are in `a_web_client_notices_a_dead_path_test.dart`, which drives the same
probe through the explicit `platformHandlesPing: false` and is therefore unaffected.
