---
round: 327
verdict: CLEAN
packages: [rpc_dart_http2, rpc_dart]
lens: RPC-02
bench: P-08 — reused
commit: yes
---

# Round 327 — the ablation RPC-02 was owed

## Target

The debt round 320 wrote into RPC-02 and rounds 322, 323 and 324 each restated
without paying: three consecutive READINGS (216 measured, 243 read, 320 read),
and the lens itself saying the next round to touch it should ablate.

Round 322 discharged the same debt on RPC-09 because the apparatus was there.
RPC-02's apparatus is there too — `P-08`, validated at round 216 — so there was
never a reason beyond not having done it.

## Hypothesis

Across 111 rounds and two rounds (325, 326) that edited these very files,
`P-08`'s control no longer separates the arms: either the cap-to-64 row stops
being clean, or the ablated row stops turning `status 8` into an
`ArgumentError`, in which case the bench is broken and every "clean" since 216
rests on nothing.

## Before

`P-08` (`.dart_tool/probe/refusal_survives_a_tight_cap.dart`), reused whole.

```
  cap    unimplemented   un-consumed window   plain call after
  8192   status 12       status 8             ok
    64   status 12       status 8             ok
    16   status 3        status 3             status 3     <- confounded
    64   status 12       ArgumentError        ok           <- ablated
```

**All four rows identical to round 216's.** The ablation is the registered one:
`maxMessageLength` removed from `_fcRefuseOverrun`'s trailer in
`rpc_http2_responder_transport.dart`. With it gone and the cap at 64, one
trailer losing its bound turns a clean RESOURCE_EXHAUSTED into a raw
`ArgumentError` at the caller, while the other two rows do not move — so the
bench still isolates the trailer rather than the request headers.

Row three is the guard that keeps row two meaningful: at a cap of 16 every row
reads status 3, including the plain call, because rpc_dart's own request headers
do not fit. Nothing there can be attributed to a trailer (`../checked/C-21-header-cap-has-a-floor.md`).

## Mechanism

Nothing is broken. The keeper is that the measurement, not the reading, is what
"every site passes the cap" has ever meant — and it now holds on a tree 111
rounds and 5 doc-and-lint sweeps away from where it was taken.

**The sweep count is also unchanged**, but it took more care than last time:

```
grep hits for RpcMetadata.forTrailer                    20
  minus the declaration in metadata.dart                -1
  minus three COMMENTS that name it                     -3
assembly sites                                          16   (243: 16, 320: 16)
  pass a message                                        12   (243: 12, 320: 12)
    ...and carry a cap                                  12
  pass none (always fit)                                 4
```

> **A window-based grep gets this wrong.** Checking each site for
> `maxMessageLength:` within 8 lines reports **11 of 12**: at
> `frame_multiplexed_channel.dart:261` the cap sits ELEVEN lines below the
> `forTrailer(`, behind a six-line comment explaining why an INBOUND trailer
> needs one. The one site whose cap is best documented is the one a naive
> detector calls missing.

## After

```
RPC-02   swept here (round 320, 3228c5de)  ->  swept here (round 327, 1ab3e26e)
```

The status field says `swept` because that is the only sweep value the lens
schema has. The distinction this round exists for — measured, not read — lives
in the lens body and here, which is where a reader looking for it will be.

## Canary

The ablation IS the canary and it is the registered one. Reverted, the same row
reads `status 8` again; `rpc_dart_http2` is `+204`, unchanged.

## Gate

No code changed — the ablation was reverted and `git status` is empty.
`rpc_dart_http2` `+204` after the revert. Last full gate at round 326: analyze
clean over 21 packages plus `rpc_dart_wasm`, `format:check` clean, `test:unit`
14 packages 0 failures.

## Not fixed

Nothing to fix.

The debt this round clears was open for seven rounds and named in four records.
What made it stick was not cost — the whole round is one probe run, one edit and
one revert — but that each round preferred a fresh target to an owed one.

`curate` remains overdue since ~234 and is now the oldest open item by a wide
margin.

## Links

RPC-02 (`applied:` gains 327; status becomes an ABLATION rather than a sweep),
`P-08` reused with its control repeated first. RPC-15 for the discipline that
produced the debt and kept it visible until it was paid.

What this adds to RPC-02: its detector must discount the declaration and the
comments that name it (4 of 20 hits), and must not look for the cap in a fixed
window below the call — the best-documented site is the one that hides furthest
from it.
