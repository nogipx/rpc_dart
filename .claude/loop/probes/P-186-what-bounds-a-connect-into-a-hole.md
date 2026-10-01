---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b182_connect_has_no_bound.dart
round: 563
commit: 4b16b2fd
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-186 — what bounds a connect into a hole?

## Why it exists

B-182 says `RpcHttp2CallerTransport.connect` awaits `Socket.connect` / `SecureSocket.connect` with no
timeout, and that `_proxyHandshakeTimeout` bounds only a proxy's CONNECT response. That field's own doc
names the consequence — *"Unbounded, this hangs an application at STARTUP"* — so the claim is the code
agreeing with a comment about a different call, which is worth measuring rather than believing.

## The harness

Three attempts, each timed, each capped so the probe ends:

- **a REFUSED port** — a loopback port with no listener, which sends RST. The control for "prompt
  failures are unaffected".
- **a BLACK HOLE with the bound passed explicitly** — `198.51.100.1`, TEST-NET-2 (RFC 5737), reserved
  for documentation and not routed, so its SYN is dropped rather than refused.
- **the same black hole with the bound OFF**, which is what the code did before.

**The bound is passed explicitly rather than taken from the default.** The shipped default is 30 s, so
a probe capped below it sees neither the fix nor the defect — the first version capped at 12 s and
reported `STILL PENDING` after the fix was already in.

## The numbers (round 563)

```
  refused, bound at 2s        OSError after 10ms
  black-holed, bound at 2s    OSError after 1730ms
  black-holed, bound OFF      STILL PENDING at the probe cap of 8s
```

## Measures

Wall-clock to the first terminal outcome, and which outcome it was.

## Control

Two, and the round needs both.

**The refused row** says a prompt failure is still prompt: 10 ms with the bound in place, so the knob
does not slow the ordinary error path.

**The bound-OFF row is the one that makes the middle row mean anything.** Without it, `1730ms` could be
the network answering rather than the timeout firing — and the OFF row shows the same address still
pending at 8 s, so the OS was not going to answer at 1.7 s.

## What it establishes, and what it does not

Establishes that the connect had no bound of its own, that the knob now provides one, and that a
refused address is unaffected.

**Does NOT belong in the gate, deliberately.** The arm depends on how the network treats a reserved
address — a firewall that REFUSES `198.51.100.1` instead of dropping turns the black-hole rows into the
refused row, and the test would fail for a reason that has nothing to do with the code. That is the
B-196 class, and round 563 declines to add to it: the evidence is here, and no test was put in the
tree.

Does NOT cover the proxy path's own `Socket.connect`, or the TLS handshake separately from the socket —
`SecureSocket.connect`'s `timeout:` covers both together and the probe does not separate them.
