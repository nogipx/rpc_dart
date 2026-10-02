---
status: closed (round 620)
round: 620
commit: 1e8bf772
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
probe: P-151
reason: "FIXED in round 620 by the owner's choice: a gzip payload no longer than the format's 20-byte minimum is sent plain without compressing (17.86 -> 0.11 us at 16 B), and the two copies are gone; the threshold trade-off above that stays documented. Previously: cost — the GROWTH half is fixed by comparing sizes, which pays slightly MORE CPU than the threshold the sketch asked for; nothing measured that, and two `Uint8List.fromList` copies are untouched"
---

# B-206 — comparing sizes fixes the growth and pays for it in CPU nobody measured

Split out of B-122, which round 513 closed the growth half: `compressIfSmaller` sends the
smaller of the two, so a 32 B payload no longer leaves as 62 B, with the crossover between
192 and 256 B. Bench `../probes/P-151-does-compression-ever-make-a-message-bigger.md`.

**The fix trades size for CPU, and the trade is unmeasured.** Compression still RUNS on
every payload; the comparison only decides what to send. So a small message now costs a
compress that is thrown away — slightly more CPU than before, where the sketch's size
threshold would have skipped the work entirely. Unknown rather than dismissed.

**A threshold is still the right tool for that half**, sitting in FRONT of the comparison
rather than instead of it: skip below N bytes, compare above it. Both, not either.

**And two copies are untouched.** `rpcGzipCompress` / `rpcGzipDecompress` each add a
`Uint8List.fromList` over the codec's output.

## Why it matters

Every message on a compressed connection pays a compress, including the ones whose result is
discarded.

## Witness a round would build

P-151's rig timing the compress path rather than measuring its output: per-message cost at
sizes either side of the crossover, with a threshold arm in front of the comparison. The
control is the pre-513 behaviour, which paid the compress and SENT it.

## Owner decision

2026-10-02: skip only what the gzip format cannot shrink, and remove the two
copies. No configurable threshold. Carried out in round 620.
