---
round: 342
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-10
bench: P-40 — new
commit: yes
---

# Round 342 — the second mechanism that was not a field

## Target

The one open cell round 341's enumeration left: `closeOnProtocolError` honoured
by the channel transports and the http2 RESPONDER, not by the http2 caller.

## Hypothesis

The enumeration was of policy FIELDS. A shared layer can also carry behaviour
that no field names, and that kind is invisible to a field-by-field sweep — so
read what `_validateInbound` actually does rather than which fields it reads.

## Before

It does two things, and only one of them is a field:

```dart
if (_policy.closeOnProtocolError || ++_policyViolations > _maxPolicyViolations)
```

`_maxPolicyViolations = 256`, with its own price in the comment above it:

> `closeOnProtocolError` defaults to false, which says one bad frame must not
> end the connection — not that a peer may grind forever. 200k violating
> frames, 5.9 MiB on the wire, cost 100 MiB of RSS with the connection still
> open to repeat it. 256 is far past any misconfiguration.

`grep` finds no violation counter anywhere outside `RpcChannelTransport`. So the
http2 responder has the field and not the backstop, and the caller has neither.

P-40, 2000 violating header blocks at the **default** policy:

```
shared layer      delivered=301   CLOSED by the transport   RSS 235->233 MiB
http2 responder   opened=2000     STILL OPEN                RSS 234->261 MiB
```

**Every one accepted, connection still open, RSS up 27 MiB**, on the transport
the responder's own comment calls "the transport a gRPC deployment actually
exposes". Unauthenticated, at the shipped default.

## Mechanism

Round 341 enumerated the policy's fields and called the sweep terminating. It
was terminating for fields and blind to this: a backstop is a constant and a
counter, named nowhere in `RpcSecurityPolicy`, so nothing in a field list points
at it. The http2 responder's port of `closeOnProtocolError` copied the half that
had a name.

## After

The same constant and counter in both http2 halves.

```
http2 responder   opened=2000 STILL OPEN  ->  opened=601, connection closed
                  RSS 234->261 MiB        ->  RSS 233->222 MiB
rpc_dart_http2    +210  ->  +213
```

601 rather than 257 because streams are opened faster than they are rejected;
the control overshoots to 301 the same way, which is what makes the two
comparable.

**The two halves got deliberately different code.** The responder gets
`closeOnProtocolError || backstop`; the caller gets the backstop ONLY. The
library's stated position for a client is that killing the connection over one
peer fault is the wrong answer because the other in-flight calls die with it —
`closeOnOversizedFrame: !isClient`, with the reasoning written at
`channel_transport.dart:268`. A peer that has done it 256 times is no longer one
bad frame, so the backstop applies to both roles and the field does not.

## Canary

One per half, since each got its own code:

```
responder backstop ablated   Expected: false  Actual: <true>
                             'the peer sent 1500 policy violations and kept
                              its connection'

caller backstop ablated      Expected: true   Actual: <false>
                             'the server answered 1500 calls with metadata the
                              client refuses, and the client kept the connection'
```

The GUARD stayed green in both: 20 violations cost nothing, and the connection
is still a WORKING one afterwards, not merely an open socket — a real unary call
completes. That is what stops the backstop becoming `closeOnProtocolError` by
the back door, which would defeat the default the field exists to provide.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures.

## Not fixed

`rpc_dart_http` has no backstop either, and does not need the same one: HTTP/1.1
is request-scoped, so a violating request costs one request and there is no
connection to grind. Its own aggregate bound went in at round 341. Stated rather
than swept, because "add the counter everywhere" would have been the wrong
sweep.

## Links

RPC-10 (`applied:` gains 342, its third). The lens's table now records that a
field enumeration has a blind spot and what to read instead.

> **A sweep terminates over the thing it enumerates, and is blind to everything
> else.** Round 341's field-by-field pass was genuinely exhaustive and genuinely
> missed this, because the mechanism it missed has no field to be enumerated —
> it is a `static const int` and an `int`. After enumerating the names, read the
> bodies for what has none.
