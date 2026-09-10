---
round: 285
verdict: INCONCLUSIVE
packages: [rpc_dart_compression]
lens: RPC-07
bench: none
commit: yes
---

# Round 285 — the mitigation that is VM-only

## Target

`rpc_dart_compression`, the last core package with no round of its own. Its main
hazard, the gzip bomb, is already covered by C-17 across rounds 76, 107 and 108,
so the question was what the covered half leaves.

RPC-07 — green on the VM, broken on dart2js.

## Hypothesis

The ISIZE pre-check is exact only below 4 GiB, because ISIZE is the size MOD
2^32. The codec's own comment carries the VM measurement for a payload that
exploits it: 4.0 MiB of compressed zeros declaring ISIZE 4096, against a 16 MiB
limit, gave **RSS +1873 MiB and 17.5 s** before the throw. `boundedInflate` was
the fix. If that inflater is VM-only, the bomb is unbounded on web.

## Before

No bench. Established by reading two files, which is what rule one asks for
first:

```
bounded_inflate_stub.dart:28   Uint8List? boundedInflate(...) => null;
isize_wrap_bomb_test.dart:27   @TestOn('vm')
```

The stub returns null on web — stated honestly in its own doc, because
`package:archive` materialises the whole output and nothing can stop it
part-way — so the caller falls back to a whole-buffer decode and the limit is
enforced at `gzip_codec.dart:184` on `result.length`, i.e. **after the output
exists**.

And the one test that exercises this bomb is VM-only. So the single platform
lacking the defence is the single platform the test cannot run on.

**That combination is the finding, and it is not recorded anywhere.** The
MECHANISM is documented in the stub; the CONSEQUENCE — the bomb is unbounded on
web — is stated in no comment, no test and no negative.

## Mechanism

n/a — nothing new to explain; the codec explains it, one platform at a time.

## After

n/a.

## Canary

n/a.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

**INCONCLUSIVE and not CLEAN, because a reading is not a measurement** — which
is the whole lesson of round 279, where I dismissed a leftover in prose and the
owner sent me back to measure it. The reading here is strong (a function that
returns `null`, and a `@TestOn('vm')`), but "unbounded on web" is a claim about
runtime behaviour and I have not run it.

Filed as **B-29** with the probe design: feed the isize-wrap payload the VM test
already builds through `decompress` under `melos run test:web`, measuring TIME
rather than RSS — node does not expose `ProcessInfo.maxRss` the way the VM does,
and 17.5 s is a large enough signal for a clock. Controls named: the same
payload unlimited, and a same-sized payload with an honest ISIZE.

What was tried: only the reading. No bench was built, because a dart2js run with
a time observable is a different harness from anything in `probes/` and this
round had no room to build and validate one honestly.

If confirmed, the fix is not an inflater — `package:archive` cannot be stopped
part-way. Either refuse a payload whose compressed size implies a possible wrap,
or document the residual where an operator configuring `maxDecompressedSize`
will read it. That is a choice, so it is the owner's.

## Links

RPC-07 (`applied:` gains 285). Lead B-29, new. C-17 is the negative this round
sits beside: it covers message-level gzip on the VM, and this is what that
leaves.
