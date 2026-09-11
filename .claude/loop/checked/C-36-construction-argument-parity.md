---
round: 335
scope: packages/core/rpc_dart/lib, packages/transport/*/lib
commit: bbb6c63d
paths: [packages/core/rpc_dart/lib/src/endpoint/**, packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http2/lib/**]
---

# C-36 — every other multi-site construction passes the same arguments

## The detector, and why it was worth running

Round 334 found `UnaryCaller` constructed with no `logger:` on the serialized
branch while the zero-copy branch eight lines above passed one — so the DEFAULT
unary call had no caller-side diagnostics, ever. The lens addition it produced:

> not only "does the wrapper forward this interface" but "does every branch that
> constructs this collaborator pass the same arguments".

That is a detector, and a detector found on one instance is a guess about a
class. Round 335 ran it over every class in core and transport constructed in
more than one place.

## Measured

```
class                     sites   verdict
CallProcessor               4     consistent
stream responders (7 kinds) 8     all pass `logger: contextLogger`
stream callers              4     ONE omission -> round 334; other three agree
RpcMessageParser            3     two expression differences, both benign
RpcChannelTransport         8     all pass `policy:`
                           ---
                            27    1 defect, already fixed
```

## The two that needed reading the VALUE, not the text

Both would be false positives for a textual comparison, and both took a second
look to clear:

**1. `maxBufferedBytes`.** Core's `_policyBoundParser` passes
`policy.effectiveMaxBufferedBytes`; http2's two transports pass the raw nullable
`_policy.maxBufferedBytes`. Different expressions — and identical results:

```
effectiveMaxBufferedBytes  =  maxBufferedBytes ?? (maxMessageLengthBytes + prefix)
RpcMessageParser's own     =  maxBufferedBytes ?? (maxMessageLength     + prefix)
```

and `maxMessageLength` is `policy.maxMessageLengthBytes` at every site. The
fallback is written twice and agrees.

**2. `decompressor`.** Core passes one; http2's per-stream parsers pass none.
Deliberate layering, stated in the parser: with no decompressor it re-encodes
the frame with the compression bit set and passes it up, so the ENDPOINT's
parser decompresses. A transport parser that decompressed would do it twice.

## Control

The detector's sensitivity is not assumed — it is round 334. The same reading,
applied to the same corpus one round earlier, found a real defect whose symptom
(no logs on the default unary path) had been invisible since the class was
written. A sweep that finds 1 in 27 with that provenance is a measurement; the
same sweep with no prior find would be hope.

## What would change this

A new construction site, or a new optional parameter on any of these classes.
The check is cheap — list the sites, diff the named arguments, read the value
where the text differs — and it is worth repeating whenever one of these
classes gains a parameter, because the analyzer says nothing about an optional
argument nobody passed.
