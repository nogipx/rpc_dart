---
round: 341
verdict: FIXED
packages: [rpc_dart_http, rpc_dart]
lens: RPC-10
bench: P-39 — new
commit: yes
---

# Round 341 — the knob that bought a belief

## Target

The detector round 340 left behind. RPC-10's question generalises the two
comments in http2 that name `RpcChannelTransport` behaviours someone noticed
missing and ported by hand — so the list to work through is what the shared
layer does that a hand-rolled transport must re-implement.

Taken as an enumerable question rather than a hunt: **which fields of
`RpcSecurityPolicy` does each transport actually honour?**

## Hypothesis

A field is either enforced everywhere it applies or it is a knob that does
nothing somewhere. `security_policy.dart:50` already states the rule:

> Do NOT add a field here that nothing enforces. [...] setting one bought a
> belief and no behaviour -- and an operator hardening a deployment stops
> looking once the knob is set.

## Before

Grepping each field across the five transports, one stood out.
`maxMetadataBytes` is consumed in three places:

```
frame_multiplexed_channel.dart:223,404   websocket, wasm
http2_header_block_guard via :518, :555  http2 caller and server
```

and in **none** of `rpc_dart_http`. Its responder validates headers with
`policy.validateMetadata` (`:268`), which covers `maxHeaders`, the name and
value caps and the method path — **and those do not imply a total.** The
defaults allow 128 headers of 8 KiB: 1 MiB against a 64 KiB bound.

P-39, one raw HTTP/1.1 POST per row:

```
                    header bytes   reply
4 x 100                      400   200 OK
100 x 1000                100000   200 OK    <-- over the bound, accepted
120 x 8000                960000   200 OK    <-- over the bound, accepted
```

**960 000 bytes of headers, answered 200 OK, 14.6x the configured bound**, every
individual header legal. dart:io imposes no limit of its own, so nothing else
was catching it. Pre-auth, from any peer, on a transport whose whole job is to
face the public internet.

The control — a second server at `maxHeaders: 8` — refuses the same requests
with 400, so the bench can produce a refusal and the 200s mean what they say.

## Mechanism

The field's own doc scoped it wrongly:

> Max encoded metadata payload size for transports that serialize metadata
> (for example, JSON over WebSocket).

http2 does not serialize metadata either — it applies the same number to its
HPACK header block. So two native-header transports made opposite choices and
the prose described neither, which is why the gap read as intentional.

## After

Enforced in the http responder, next to the existing per-header validation, and
the doc rewritten to say what the field means.

```
100 x 1000                100000   200 OK  ->  400 Bad Request
120 x 8000                960000   200 OK  ->  400 Bad Request
4 x 100                      400   200 OK  ->  200 OK
rpc_dart_http                      +123    ->  +126
```

**Counted in the transport, not in `validateMetadata`.** Each transport knows
its own byte count — the frame channel the serialized payload, http2 the HPACK
block, this one the header lines — and putting one string-length approximation
in the shared method would have given three transports a second, differently
accounted check that can disagree with the one they already have.

## Canary

```
the bound ablated   Expected: contains '400'
                    Actual: 'HTTP/1.1 200 OK'
                    '960 000 bytes of headers against a 64 KiB bound'
```

Two GUARDs stayed green in the ablated run and are what stop the fix being "400
everything": an ordinary 4-header block still passes, and a block that is small
in total but breaks `maxHeaders` is still refused for its OWN reason — the
aggregate check runs first and could have shadowed it.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures.

## Not fixed

The isolate transport does not apply `maxMetadataBytes` either, and that stays
deliberate: RPC-10's own round-197 measurement is that reaching its channel at
all means arbitrary code in this process, so the trust boundary is not a peer's.
Now written on the field rather than left to be rediscovered.

The enumeration produced a second candidate not taken here: `closeOnProtocolError`
is honoured by the channel transports and the http2 RESPONDER (`:412`) and not
by the http2 caller. Whether a caller should tear down its connection on a peer's
protocol violation is a different question from whether a server should, so it
needs its own round rather than a line in this one.

## Links

RPC-10 (`applied:` gains 341, its second). Round 340 found one missing behaviour
by reading; this found the next by ENUMERATING the policy fields, which is the
cheaper form of the same question and the one that terminates.

> **An unenforced limit is worse than a missing one, and the file says so three
> lines above the field it happened to.** The comment at
> `security_policy.dart:50` was written after three such fields were deleted;
> `maxMetadataBytes` survived the cull because it IS enforced — on four
> transports out of five.
