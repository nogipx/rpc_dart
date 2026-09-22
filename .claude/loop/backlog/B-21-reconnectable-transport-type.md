---
status: closed (round 430)
round: 224
commit: ed1a54bc
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart
reason: decided — ship it with the major already accruing; the lead's own condition (alongside something else that breaks the signature) is met by `feat(rpc_dart)!: make RpcException abstract`
---

# B-21 — make the reconnect capability a compile-time requirement

Round 224 refuses a transport without `IRpcStreamIdSequence` at attach, so the
data loss is gone. The refusal is a **runtime** one: the developer learns on the
first run, from a `RpcClientDisconnected` and an error log.

The honest end state is a type:

```dart
abstract interface class IRpcReconnectableTransport
    implements IRpcTransport, IRpcStreamIdSequence {}
```

as `RpcClientConnection`'s `transportFactory` return type. A decorator author
then gets a compile error at the factory, pointing at the exact members to
forward, instead of a message at run time.

## Why round 224 did not do it

- **It is a separate breaking change**, on the signature rather than the
  behaviour, and the owner authorised the refusal and said in as many words not
  to smuggle this into it.
- Every first-party caller transport would have to declare the new interface.
  Mechanical, but it touches five packages rather than one.
- It fixes nothing that is currently broken: after round 224 the failure is
  loud, early and self-explanatory. This makes it earlier still.

## When to take it

The next major of `rpc_dart`, alongside whatever else breaks the signature.
Doing it on its own would spend a major version on a diagnostic improvement.

**That condition is now met.** Two commits on this lead's own paths say so:

```
27d22cd1  feat(rpc_dart)!: make RpcException abstract; every error names its status
8d81b9e7  fix(rpc_dart): forward transport capabilities through the reconnecting proxy
```

The first is a breaking change already shipped, so the major is accruing and
this rides along instead of spending one. The second is this lead's own subject
arriving as a runtime repair — a capability forwarded through a decorator,
fixed one member at a time, which is exactly what the type makes impossible to
get wrong.

## Owner decision

**Taken: ship it with this major.**

The carrying round does three things, and the third is the one that can go
wrong:

1. declare `IRpcReconnectableTransport` and use it as `RpcClientConnection`'s
   `transportFactory` return type;
2. have every first-party caller transport declare it — mechanical, five
   packages;
3. **re-check the claim that it fixes nothing currently broken.** The curate
   after 327 ranked this lead up precisely because eight `fix()` commits have
   landed on `client_connection.dart` and `transport.dart` since its number was
   taken, and that claim is the one most likely to have decayed. `8d81b9e7`
   above is evidence it already has.

Round 224's runtime refusal stays either way — the type is the earlier warning,
not a replacement for the guard.

## CLOSED — round 430. One of the two claims was false.

**Claim 1 holds.** P-09 reused, control repeated first, reads exactly what round
224 left: the transport itself comes online at id 3 with `0 -> 0`, the plain
decorator is REFUSED and the reason names the capability. Nothing was broken.

**Claim 2 — "the runtime refusal stays either way" — is false in effect.** With
the typed factory, a non-conforming transport can only arrive through a cast,
and the implicit downcast throws BEFORE the value reaches the `is!` guard:

```
                        round 224      through the type (as first built)
state                   Disconnected   RpcClientConnecting
transports built        1              2 and counting
reason names remedy     yes            no -- a bare TypeError
```

The type walks past the guard, and the failure degrades into the backoff spin
224's GUARD test exists to prevent. **The owner's call on the measurement: ship
the type AND restore the one-shot refusal**, which `RpcClientConnection` now
does by treating a factory `TypeError` as non-transient.

### What the analyzer found that this lead did not list

39 sites. Item 2 says "every first-party caller transport would have to declare
it — mechanical, five packages", and that is the smaller half:

```
declare the marker        RpcChannelTransport, RpcHttpCallerTransport,
                          RpcHttp2CallerTransport, RpcWebSocketCallerTransport
declared type ERASED      RpcInMemoryTransport.pair
the capability            RpcIsolateTransport.spawn (x3)
                          RpcWasmTransport.fromBridge
rpc_dart_log              one library caller, green once websocket declared it
resilience tests          32, all test doubles
```

The three erased entry points returned objects that always conformed while
their signatures said `IRpcTransport`. Left alone, a factory using any of them
would not compile on code that works today.

### Residue

The runtime guard below the await is unreachable from sound Dart and stays, as
the second line for `dynamic`/interop/casts. Every third-party transport that
implements both interfaces separately stops compiling — the cost of a nominal
marker, and one for the major's changelog. Two witnesses now need a deliberate
`dynamic` hop to express the non-conforming case, and both say so in place.

`../rounds/430-the-guard-the-type-walked-past.md`.
