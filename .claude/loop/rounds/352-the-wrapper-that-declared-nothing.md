---
round: 352
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: P-44 — new
commit: yes
---

# Round 352 — the wrapper that declared nothing

## Target

The owner's 6.0.0 review list, P0 item 2. RPC-04 exactly: a capability hidden by
a wrapper, whose `breaks:` is *"security hole: limits silently switched off with
the tests green"*.

**Scope counted before the fix.** The class is *every wrapper around
`IRpcTransport` in the workspace* — the lens's own note says the surface is much
smaller than its paths suggest, and it is. Three:

```
wrapper                                    forwards
RpcWebSocketCallerTransport                all four
_CapabilityPreservingTransport (http2)     policy + flow control, and its
                                           inner declares nothing else
_ReconnectingTransportProxy                IRpcStreamReset alone
```

So one defective wrapper, and it drops four things: `IRpcSecurityPolicyAware`,
`IRpcFlowControlled`, `IRpcStreamIdSequence` and `supportsZeroCopy`, the last
hardcoded to `false`. `RpcWebSocketCallerTransport`'s class comment already
states this defect in the abstract, over the class that has it — U-14, the
sibling that got it right.

## Hypothesis

`RpcClientConnection` is documented as *"the recommended, transport-agnostic way
to get auto-reconnect on a client"*, so its proxy is what most applications hand
to an endpoint. If the capability checks above it fall back silently, then an
endpoint built on the proxy enforces DIFFERENT limits from one built on the same
transport directly — and nothing says so.

It fails to hold if the layers read these off something other than the transport,
or if the fallbacks happen to coincide with the configured values.

## Before

```
effect     arm       result
policy     direct    20 MiB received
policy     proxy     gRPC frame buffer overflow: 20971533 bytes (max: 16777221)
zerocopy   direct    accepted, 3 bytes back
zerocopy   proxy     Invalid argument(s): Zero-copy requires a transport that...
flowctl    direct    deferred=1
flowctl    proxy     deferred=0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/capabilities_through_the_proxy.dart`.
One variable: whether the proxy sits between the endpoint and the same transport
object.

`max: 16777221` is 16 MiB plus the 5-byte prefix — `const RpcSecurityPolicy()`'s
own `effectiveMaxBufferedBytes`. The number names which policy the parser was
built from, against the 64 MiB the transport was configured with.

## Mechanism

The four capabilities are deliberately separate from `IRpcTransport` so a
third-party transport keeps compiling when one is added; every consumer probes
with `is` and falls back to a safe default. `_ReconnectingTransportProxy`
declared `IRpcTransport, IRpcStreamReset`, so every probe missed:
`_policyOf` returned `const RpcSecurityPolicy()`, `_pipelineFedRequestStream`
found no `IRpcFlowControlled` and credited on arrival instead of on consumption,
and `supportsZeroCopy` was a literal `false` over a transport whose
`sendDirectObject` the proxy has always delegated.

## After

```
effect     arm       result
policy     direct    20 MiB received
policy     proxy     20 MiB received
zerocopy   direct    accepted, 3 bytes back
zerocopy   proxy     accepted, 3 bytes back
flowctl    direct    deferred=1
flowctl    proxy     deferred=1
```

The policy and the zero-copy answer are also REMEMBERED from the last attach.
The responder pipeline's limit caches are `??=`, so a read landing in a
reconnect gap would otherwise pin the defaults for the endpoint's whole life —
the defect arriving by a second route.

## Canary

Four capabilities, four canaries, each switched off in place and each failing
exactly one witness while the other three stayed green:

```
securityPolicy -> const RpcSecurityPolicy()
  gRPC frame buffer overflow: 20971533 bytes (max: 16777221)
supportsZeroCopy -> false
  Expected: true  Actual: <false>   the proxy hardcoded false over a transport
                                    that supports it
deferFlowCredit -> return
  Expected: <1>  Actual: <0>        without IRpcFlowControlled on the proxy the
                                    pipeline credits on arrival
lastIssuedStreamId -> -1
  Expected: a value greater than <0>  Actual: <-1>
```

Isolating cleanly is the point: one shared canary would have proved one
forwarding and been read as proving four.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS over 14 packages;
`melos run format:check` SUCCESS; `melos run license:check` — 1340/1340 files.
Plus `fvm dart test -j 8` in the changed package: `+1460 ~1`, all passed.

## Not fixed

**`IRpcStreamIdSequence` has no in-repo consumer**, and that is worth stating
rather than implying: `grep -rn IRpcStreamIdSequence` over every `lib/` finds the
interface, the transports that implement it, and the proxy's own internal use —
nothing READS it on a transport handed to it. Its witness is therefore a
contract assertion (the cursor does not regress across a reconnect) rather than
an observed failure. It is forwarded because it is part of the class and a
third-party layer can read it; the other three are what were measurably broken.

**Zero-copy changes what an existing `auto` call does.** Over a zero-copy
transport behind `RpcClientConnection`, a codec-based call with the default
`RpcDataTransferMode.auto` now takes the object path instead of serializing —
faster (measured elsewhere at 514 us against 807 us) and what the transport
already does without the proxy, but it means the byte limits stop applying to
that call, as they always do on the object path. The owner's item asked for
`supportsZeroCopy` explicitly, so this is the requested behaviour, recorded here
because it is a semantic change and not only a repair.

## Links

Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` (eighth application;
the first instance in core's own resilience layer).
Bench `../probes/P-44-capabilities-through-the-proxy.md`, new.
Catalog shapes U-05 and U-14.
