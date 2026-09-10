---
round: 286
verdict: DEFERRED
packages: [rpc_dart_compression]
lens: RPC-07
bench: P-34 — new
commit: yes
---

# Round 286 — twelve milliseconds against sixteen seconds

## Target

B-29, filed by round 285 from a reading and left INCONCLUSIVE because a reading
is not a measurement. This builds the bench it named.

## Hypothesis

`boundedInflate` is the mitigation for a gzip payload whose ISIZE understates
its real output, and on web it is `=> null`. So the refusal costs the full
inflate there, where the VM aborts mid-stream.

## Before

The fixture is the round's own contribution. `isize_wrap_bomb_test` builds a
TRUE 4 GiB wrap with `dart:io`'s encoder, which is why it is `@TestOn('vm')` —
so the platform without the defence was the one the test could not reach. This
forges the trailer instead: gzip 64 MiB of zeros, then overwrite the last four
bytes to declare 4096. Arithmetically that is what the wrap does to the
pre-check, and it builds on any runtime.

```
runtime        refused in   mechanism
VM                  12 ms   boundedInflate aborts at the limit
dart2js / node   15980 ms   no bounded inflater: 64 MiB inflated, then rejected
```

Bench: `packages/core/rpc_dart_compression/test/audit/isize_understates_on_web_test.dart`

**1332x.** Confirmed, and worse than B-29 predicted in the dimension that
matters to an attacker: 64 MiB of zeros compresses to roughly 65 KiB, so one
message of that size buys 64 MiB of allocation and sixteen seconds of a
single-threaded event loop. The contract still holds — it throws on both — but
refusing is what costs.

## Mechanism

Exactly as read in round 285, now with the number attached. The pre-check trusts
ISIZE and clears. `boundedInflate` returns null on web because `package:archive`
materialises the whole output and cannot be halted, so control falls to the
whole-buffer decode and the limit is enforced at `gzip_codec.dart:184` on
`result.length` — after the output exists.

## After

n/a — deliberately not fixed.

## Canary

n/a for a fix that was not made. The bench's own controls do the work: an honest
1 MiB payload still round-trips, so the witness cannot pass on a codec that
refuses everything, and the first assertion checks the forged trailer reads as
harmless, so the pre-check is not what refuses.

## Gate

`melos exec --scope=rpc_dart_compression -- fvm dart test` and the same with
`-p node` — both green, 2 tests each. `loop.py lint` green. No `lib/` change, so
the workspace gate is not what this round turns on.

## Not fixed

An owner decision, and I want to be plain that **I could not find a fix worth
proposing**, which is itself the finding's shape.

- **A compressed-size heuristic does not work.** The obvious bound — refuse when
  `data.length * maxDeflateRatio` could exceed the limit — is useless at deflate's
  real ceiling of about 1032:1: against a 16 MiB limit it would refuse every
  input over ~16 KiB, including ordinary highly-compressible traffic.
- **Chunking is not available.** `package:archive` exposes no incremental
  inflater on web; that is why the stub returns null in the first place.
- **A different web inflater** would be a dependency decision, not a round's.

So the realistic options are to document the residual where an operator setting
`maxDecompressedSize` will read it, or to accept a lower effective limit on web.
Both are choices about what the library promises, which makes them yours.

**What this round DID ship is the test**, and it earns its place independently
of the decision: it runs on both runtimes and pins the contract — over the limit
is refused, everywhere — so a future change that makes web silently return the
bytes cannot pass. It asserts the contract and only PRINTS the time, because a
threshold would pin the platform difference instead.

## Links

RPC-07 (`applied:` gains 286) — the clearest instance the lens has: not "green
on the VM, red on dart2js", but the same green with a thousandfold different
cost. Bench P-34. B-29 updated from a reading to a measurement and left open on
the decision.
