---
round: 427
verdict: FIXED
packages: [rpc_dart_compression]
lens: RPC-07
bench: P-34 — reused
commit: yes
---

# Round 427 — the number the decision asked me to write down

## Target

**B-29**, first of the four the owner listed for the rounds after 426. Its
decision is *document the residual, change no behaviour*, and it names the
number to write: **15980 ms against the VM's 12 ms**.

L-13 says the round carrying a decision re-measures the SENTENCE it was taken
on, and that is the whole reason this round is not just prose: the decision's
evidence is a figure taken 141 rounds ago, on another machine, on another SDK.

## Hypothesis

The finding holds and the figure does not.

## Before

P-34 reused unchanged, run on both runtimes. Three dart2js readings, median
reported per `measurement.md` item 9:

```
                    round 286      round 427
VM                      12 ms          13 ms
dart2js / node       15980 ms       13463 ms   (13606 / 13094 / 13463)
ratio                   1332x          1036x
```

Probe: `packages/core/rpc_dart_compression/test/audit/isize_understates_on_web_test.dart`.

**The finding is intact and the figure has moved 16%.** So writing `15980 ms`
into public documentation would have planted exactly what rule one warns about:
prose carrying a number that reads like evidence and ages silently, with nothing
to check it.

## Mechanism

Unchanged from 285/286 and re-read rather than quoted: `boundedInflate` aborts
the inflate at the limit on the VM, `bounded_inflate_stub.dart` returns `null`
on web because `package:archive` materialises the whole output, and the limit
then runs on `result.length` at `gzip_codec.dart:184`.

## After

The numbers are unchanged, and that is the point of this round rather than a
gap in it: the decision forbids a behaviour change, so `13 ms` on the VM and
`13463 ms` on dart2js are what the documentation now describes, not what it
moves.

What changed is where those readings are stated. The residual is written where
an operator choosing a value will read it, in two places, and **as a shape
rather than a figure**:

- `RpcGzipCodec.maxDecompressedSize`'s doc comment — the limit is enforced after
  allocation on web, is not configurable, and is "a bound on what you accept,
  not a defence against what it costs to refuse";
- the package README, which did not mention the limit existed at all — a
  per-target table and the consequence for choosing a value.

Both point at the audit test for the current figures. That is the durable
arrangement: the test carries the number and is re-run, the prose carries the
shape and cannot go stale.

## Canary

`if (1 > 0) return null;` at the top of `boundedInflate`, against the TRUE-wrap
fixture:

```
isize_wrap_bomb_test, boundedInflate disabled
  Expected: a value less than <400>
    Actual: <2072.0625>
  inflating ran to completion: RSS grew 2072.1 MiB for a 16 MiB limit
```

~18 s and 2 GiB, which is the doc's per-target claim stated as a number: remove
the abort and the VM behaves the way web has to. Both GUARDs — an honest payload
inside the limit, an honest payload over it — stayed green.

**The first canary was invalid and is recorded because it looked valid.** The
same ablation against P-34's FORGED-trailer fixture reads **22 ms**, which looks
exactly like "the abort still worked". It is not: `dart:io`'s gzip filter
rejects the forged trailer outright (`FormatException: Filter error, bad data`)
before any inflating happens, so that number measures a guard one layer upstream
of the one under test. I had already drafted a doc paragraph explaining the
platform gap from it; it would have been wrong.

The two fixtures are NOT interchangeable, and the cheap one cannot canary this.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1595/1595
rpc_dart_compression     +25 on the VM; the node suite run 3x for the readings
```

`test:web` not swept: the only `lib/` change is a doc comment, which cannot
reach dart2js output, and the package's own node suite was run three times for
the measurement above — a narrower and stronger check than the sweep for this
round.

## Not fixed

**No behaviour change, by decision.** The two alternatives were declined when
B-29 was decided and this round did not re-open them: failing closed on web
would break every working deployment, and a lower web-only ceiling only changes
the size of the residual while refusing large honest messages on the one
platform where the user cannot raise it back.

**The VM's own residual is not documented**, because it does not exist:
`boundedInflate` is the abort, and the canary above is what says so.

## Links

- B-29 — closed; its decision is carried out, and its figure is superseded by
  the re-measurement rather than copied
- L-13 — the decision inherits the sentence it was taken on. Here the sentence
  held and its NUMBER did not, which is the case L-13 does not yet carry
- L-15 — extended: an ablation absorbed by a different guard reads exactly like
  an ablation the fix survived
- P-34 — reused and re-validated; its table is updated with today's readings
- RPC-07 — web as a separate runtime, which is the whole subject
