---
round: 578
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-17
bench: P-199 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 578 — the transfer that cost more than it saved

## Target

`B-156`, the next isolate item after round 577, and the one whose claim is a NUMBER: the channel doc
says "bytes cross without a copy ([TransferableTypedData])" while `fromList` copies while building. The
lead is graded `cost` and this time the grading is right — but its conclusion is not.

**Lens RPC-17, and the choice is worth stating because it is not a literal match.** No lens in the set
covers "a documented performance property nobody measured". RPC-17 is where the per-frame copy-cost
cluster already lives — rounds 507, 509, 511 and 513 are all filed under it — and this is that cluster in
a different package. A reader hunting copies will look there.

## Hypothesis

`TransferableTypedData` is a net loss on the small frames this transport mostly carries, so the doc's
claim is false and the shape is wrong.

## Before

Round-trip us/frame, minimum of three runs each — minima because noise on this machine only ever adds
time, the statistic round 509 settled on:

```
  size      TTD us/frame   Uint8List us/frame
        32          2.71                 2.34
      1024          2.66                 2.33
     65536         11.26                 7.87
   131072         20.44                14.03
   262144        103.71               160.67
   524288        191.85               265.50
  1048576        383.08               486.63
```

Probe: `packages/transport/rpc_dart_isolate/.dart_tool/probe/b156_ttd_vs_uint8list.dart`.

**The lead is confirmed for small frames and REFUTED for large ones.** Below ~128 KiB the plain list is
up to 46% faster; at 256 KiB and above the transfer is up to 35% faster. The sketch's parenthetical —
"or all" — would have cost 23% on a 1 MiB frame.

## Mechanism

`fromList` copies the bytes into a native buffer and attaches a finaliser. Below some size the copy plus
the allocation costs more than the cheaper hand-off saves; above it the transfer's avoided
deep-copy wins. The doc asserted the second half for every size.

## After

A threshold: at or above 256 KiB a frame is sent as `TransferableTypedData`, below it as the
`Uint8List`. **The receive side needed no change** — `_materializeBytes` already accepts either, which
is what made this a one-line send-side fix rather than a protocol change.

The class doc now says what the code does, and the threshold constant carries the numbers that chose it.

## Canary

**The witness is the rate table and its ablation is the TTD column**, which the probe measures in the
same run: forcing every payload through the transfer is what the `TTD` numbers ARE, and they are worse
below the threshold at every measured size.

The accompanying test is a GUARD, not a witness, and it says so in its own header: it checks that a
1 KiB and a 512 KiB payload both arrive whole, one either side of the threshold. Ablating the threshold
leaves it green, as it should — correctness is not what the threshold changes.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_isolate +93
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2199 / 2199, REUSE compliant
```

## Not fixed

**The numbers are from RAW ports, not through the transport.** The probe round-trips
`TransferableTypedData.fromList([payload])` against `payload` over a bare `SendPort`/`ReceivePort` pair —
exactly the two expressions the channel chooses between — so the comparison is sound, but the transport's
own per-frame overhead sits on neither arm and the absolute figures are not a frame's true cost. A rate
measured through `RpcIsolateTransport.spawn` would be the stronger reading and was not taken.

**The crossover band is not measured.** 128 KiB favours the plain list and 256 KiB the transfer;
anything between is interpolation, and the threshold sits at the first measured size that wins rather
than at the true crossing.

**No arm varies the frame MIX.** The argument that this transport mostly carries small frames comes from
reading what it sends (grants, headers, the 5-byte-prefixed payloads), not from counting a real
workload's distribution.

**The web bridge is untouched** and sends bytes a different way — `B-160` is its own lead.

## Links

Lead `../backlog/B-156-isolate-transferable-typed-data-is-not-zero-copy.md` — CLOSED.
Lead `../backlog/B-160-isolate-web-bytes-travel-as-js-arrays.md` — the web half, untouched.
Round `577-the-process-that-could-not-exit.md` — the previous isolate round.
Bench `../probes/P-199-what-the-transfer-costs-by-size.md` — new.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [578]`, as the copy-cost cluster's
home rather than a literal match; see `## Target`.
Lesson: none. Minima across runs and "a sketch's conclusion is not its measurement" are both already
written — `measurement.md` item 9 and `L-13` respectively.
