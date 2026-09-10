---
status: open
round: 285
commit: 9b82b12a
paths: [packages/core/rpc_dart_compression/lib/**, packages/core/rpc_dart_compression/test/audit/isize_wrap_bomb_test.dart]
probe: none yet — the design is below
reason: "bench — established by reading two files; measuring it needs a dart2js run and a TIME observable rather than RSS, which node does not expose the way ProcessInfo does"
---

# B-29 — the ISIZE bomb's mitigation does not exist on web

`RpcGzipCodec.decompress` pre-checks the gzip ISIZE trailer before allocating.
That check is exact only below 4 GiB, because **ISIZE is the size MOD 2^32**: a
payload inflating to `k*2^32 + small` declares `small` and clears the pre-check.
The codec's own comment carries the VM measurement — 4.0 MiB of compressed zeros
declaring ISIZE 4096, against a 16 MiB limit: **RSS +1873 MiB and 17.5 s** before
the throw.

The fix for that was `boundedInflate`, an incremental inflater that aborts the
moment the output passes the limit. On the VM it is `dart:io`'s converter.

**On web it does not exist.** `bounded_inflate_stub.dart:28`:

```dart
Uint8List? boundedInflate(Uint8List data, int limit) => null;
```

with the reason stated honestly right above it — `package:archive` materialises
the entire output before handing it over, so nothing can stop it part-way. The
caller falls back to a whole-buffer decode and the limit is enforced at
`gzip_codec.dart:184`, on `result.length`, i.e. **after the output exists**.

So the mitigation is VM-only, and the residual on web is the same shape the
bounded inflater was built to remove.

## Why this is not already recorded

`isize_wrap_bomb_test.dart` is `@TestOn('vm')`. The one test that exercises this
bomb cannot run on the platform that lacks the defence. `b2_web_malformed_input_test.dart`
runs everywhere but is about malformed input, not amplification.

That combination is RPC-07 exactly: green on the VM, and the guard making it
green is absent on dart2js. The mechanism is documented in the stub; the
CONSEQUENCE — that the bomb is unbounded there — is stated nowhere.

## The probe that settles it

Feed the isize-wrap payload the VM test already builds through `decompress`
under `melos run test:web`, and measure **TIME**, not RSS: node does not expose
`ProcessInfo.maxRss` the way the VM does, and the VM run showed 17.5 s, which is
a large enough signal to read on a clock.

Control: the same payload with a limit of `_unlimited`, and a same-sized payload
whose ISIZE is honest. If web time tracks the honest payload, the fallback is
somehow bounded; if it tracks the bomb, it is not.

Expected from the code: unbounded, because nothing between the pre-check and
`result.length` can stop it.

## What the fix would be, if confirmed

Not the inflater — `package:archive` cannot be stopped part-way. Either refuse a
payload whose compressed size implies a possible wrap (compressed bytes times
the maximum deflate ratio against the limit), or document the web residual where
an operator configuring `maxDecompressedSize` will read it. The first is a real
bound; the second is honest. Ask before choosing.

## Owner decision

—
