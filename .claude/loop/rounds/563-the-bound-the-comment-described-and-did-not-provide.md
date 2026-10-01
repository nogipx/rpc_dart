---
round: 563
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-08
bench: P-186 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 563 — the bound the comment described and did not provide

## Target

B-182, taken for a filed consequence that hangs the owner's own application at startup: `connect` and
`secureConnect` await `Socket.connect` /
`SecureSocket.connect` with no timeout, so *"an application that hangs at startup against a black-holed
host"*.

Lens RPC-08 in its field form: a bound that exists for one phase of an operation and not the others.

## Hypothesis

From the lead, and from `_proxyHandshakeTimeout`'s own doc, which names the consequence exactly:
*"Unbounded, this hangs an application at STARTUP: `connect()` is what it awaits"* — while bounding only
a proxy's CONNECT response.

## Before

```
  refused (loopback, no listener)   SocketException after 10ms
  black-holed (198.51.100.1)        STILL PENDING at the probe cap of 12s
```

Bench `../probes/P-186-what-bounds-a-connect-into-a-hole.md`. `198.51.100.1` is TEST-NET-2, reserved and
not routed, so its SYN is dropped rather than refused — which is the difference between the two rows.

**CONFIRMED.** A prompt failure takes 10 ms; a dropped SYN had no bound of ours at all, leaving the OS
default, which is around 75 s and can be longer.

## Mechanism

A `connectTimeout` parameter on both `connect` and `secureConnect`, defaulting to 30 s — the same
number its proxy sibling already uses, since the two bound phases of one operation.

**Passed as `timeout:` to dart:io, not wrapped in `.timeout()`.** The wrapper would abandon the FUTURE
while the connect carried on, leaving a socket nobody holds and nobody closes; `Socket.connect`'s own
parameter releases the attempt. On the TLS path the one argument covers the handshake as well.

Null restores the old behaviour of waiting on the OS, and the field's doc says so.

## After

```
  refused, bound at 2s        OSError after 10ms
  black-holed, bound at 2s    OSError after 1730ms
  black-holed, bound OFF      STILL PENDING at the probe cap of 8s
```

The bound is driven explicitly rather than taken from the default, because **the default is longer than
any probe worth running**: the first version capped at 12 s and reported `STILL PENDING` after the fix
was already in, which reads exactly like the defect.

## Canary

**The bound-OFF row IS the canary**, and it is in the probe rather than in a test: the same address,
the same rig, the mechanism switched off by argument, still pending at 8 s where the bounded arm fails
at 1.7 s.

It also does the job no assertion could: without it, `1730ms` might be the network answering rather than
the timeout firing, and the OFF row shows the OS was not going to answer at 1.7 s.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

**No test was added to the tree, and that is a decision rather than an omission.** The witness needs an
address whose SYN is DROPPED, and whether a given network drops or refuses `198.51.100.1` is not
something this repository controls — a firewall that refuses it turns the black-hole rows into the
refused row and the test fails for a reason unrelated to the code. That is precisely the B-196 class
this journal has spent rounds complaining about, so the evidence stays in the probe.

## Not fixed

**The proxy path's own `Socket.connect` is untouched.** `_connectH2ViaProxy` takes a
`handshakeTimeout` for the CONNECT response and opens its socket separately; the lead lists that as its
own site and it needs the same argument threaded through. The direct paths are what the witness
measures.

**The reconnect path inherits the bound but was not measured.** `createConnection` is also the
`connectionFactory`, so a reconnect gets the timeout for free — and the lead's note that *"single-flight
reconnect makes every caller join a hung attempt"* is now bounded by construction rather than by a
reading.

**30 s is a number nobody measured.** It matches the proxy sibling, which is a consistency argument
rather than evidence about what a slow link needs. An operator on a satellite link may need more, and
the knob is there.

## Links

Lead `../backlog/B-182-http2-connect-has-no-timeouts.md` — the direct paths fixed, the proxy socket
left.
Bench `../probes/P-186-what-bounds-a-connect-into-a-hole.md` — new.
Lead `../backlog/B-196-the-web-worker-suite-flakes-at-load.md` — the class this round declined to join.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [563]`.
