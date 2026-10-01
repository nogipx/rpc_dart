---
round: 591
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: P-209 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
---

# Round 591 — the refusal pays for its own cleanup

## Target

`B-207` — when the decompression size limit throws inside the chunked gzip decoder,
`sink.close()` is never reached, so the native zlib filter is left to a finaliser
"at a rate the peer chooses".

Lens RPC-22: the refusal path is reachable by anyone, and what it COSTS the server is
the question. The lead also names RPC-16, a check whose failure path skips a release.

## Hypothesis

The mechanism is a reading and holds. The CLAIM is a rate, and a rate needs a number.

## Before

```
                 CONTROL   WITNESS
2000 attempts    +12 MiB   +12 MiB
20000 attempts   +30 MiB    +6 MiB
20000 attempts   +31 MiB   -53 MiB
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b207_what_a_refused_bomb_leaves_behind.dart`.

**The control is the arm that grows.** 20000 successful decompressions, which DO reach
`close()`, climb more than 20000 refusals which skip it — the third run has the
witness handing 53 MiB back to the collector mid-arm.

## Mechanism

The mechanism the lead describes is real: `_LimitedByteSink.add` throws, `sink.add(data)`
is the caller, and `sink.close()` on the next line is jumped over. 20000 of 20000
attempts threw, so it was skipped 20000 times.

**What is not real is the consequence, and the reason is structural rather than
lucky.** To trip the limit a payload must be decompressed UP TO the limit — a megabyte
of output accumulated in a `BytesBuilder` before the throw. So the refusal path
generates the GC pressure that runs the finaliser, every time, in proportion to the
limit it is about to breach. A peer cannot ask for a refusal cheaply, which is exactly
what "at a rate the peer chooses" would require.

## After

**No code change.** The lead's sketch — `close()` in a `finally` — was priced and is
free of the hazard it appeared to have:

```
bomb      caller gets FormatException; close() after the throw was CLEAN
ordinary  no throw at all
```

So it could be applied. It is not, because nothing witnesses it: there is no arm that
goes red without it, and a release this round measured as unnecessary is a change the
next reader cannot tell from a change that matters. `B-207`'s own words were that the
round "is mostly the measurement", and the measurement came back negative.

## Canary

None, and none is possible. There is no fix to switch off.

What stands in for it is the control: an arm that SHOULD accumulate if the mechanism
mattered, driven 20000 times, growing less than the arm that cleans up properly.

## Gate

Not run — `lib/` and `test/` are byte-identical to the previous commit. The only
files this round adds are the probe (gitignored) and the journal.

```
git diff --stat -- packages   (empty)
```

## Not fixed

**Nothing, and that is the verdict.** The lead is REFUTED on its claim and closed.

**The condition the probe cannot create is named rather than waved at**: low GC
pressure. If refusals could be driven without allocating, the finaliser might lag —
but they cannot, for the structural reason above. That is the round's finding and the
reason this is CLEAN rather than INCONCLUSIVE.

**Dart exposes no handle on an outstanding zlib filter**, so RSS is the only
observable. It is the whole process's, which is acceptable for a probe run alone and
would not be for a test — `B-224` is the file on that.

**The `maxOutputBytes == null` path is untouched** and does not use the chunked sink
at all, so it has no `close()` to skip.

## Links

Lead `../backlog/B-207-a-zlib-sink-is-never-closed-when-the-limit-throws.md` — CLOSED, REFUTED.
Bench `../probes/P-209-what-a-refused-bomb-leaves-behind.md` — new.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` — `applied: [591]`.
Round `513` — B-122, which named this and said it deserved its own lead.
