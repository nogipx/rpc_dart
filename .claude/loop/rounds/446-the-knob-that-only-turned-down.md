---
round: 446
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-100 — new
commit: yes
severity: S2
---

# Round 446 — the knob that only turned down

## Target

B-72, next on the rank after 445 closed B-74, and decided by the owner: delete
the four private constants, read the limits from the policy, make the overflow
loud. Its premise was checked against the tree first — the lesson 445 paid for —
and this time it held: `git log` shows nothing touching either path since the
lead's commit, and the four constants are still there.

Scope taken before the fix: all four of `RpcContext`'s private limits, and both
of the mechanisms enforcing them (`continue` for the length pair, `break` for the
count and total bytes). Not in scope: the structural drops — empty key,
pseudo-header, off-pattern, CR/LF/NUL — which bound nothing and are not a second
copy of anything.

## Hypothesis

The four constants are equal to the policy's defaults and reachable from no
policy, so the knob is monotone downward only: raise `maxHeaders` and the context
still truncates at 128, dropping the remainder with no signal to the sender.

## Before

```
                              kept    policy says
A1 default, 200 sent          128     refuses 200
A2 RAISED to 512, 200 sent    128     accepts 200
A3 LOWERED to 16, 200 sent    128     refuses 200
A4 CONTROL, 10 sent            10     accepts 10

E2E, policy 512, 200 sent:  context held 128, handler saw 127,
                            call SUCCEEDED with 73 headers missing
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/context_limits_vs_policy.dart`

The probe already existed under `.dart_tool/probe/`, written for B-72 and never
recorded by any round — `.dart_tool` is gitignored, so it was local scratch. It
was re-read and run rather than trusted, and its E2E label was wrong: it printed
"with headers missing" unconditionally, which would have read as a defect after
the fix too.

## Mechanism

`_sanitizeHeaders` is a STATIC method on a value type the user constructs before
any transport exists, so it cannot see a policy and never could. It held its own
128 / 128 / 8 KiB / 64 KiB, and enforced them by `continue`-ing past an over-long
header and `break`ing out at the ceiling. The equality with the policy's defaults
is what hid it: the two agreeing on the default is exactly why nobody noticed one
of them was unreachable.

## After

Size belongs to `RpcSecurityPolicy` alone, which throws on it. A2 now keeps 200
and the handler sees 200; over the policy's own ceiling the caller is refused
with `RpcMetadataViolation: Too many metadata headers: 205 > 128`.

## Canary

Two, one per half of the fix.

**A, the count/bytes ceiling restored in place:**

    Expected: <200>
      Actual: <127>
    the policy admits 512 and the caller set 200, so all 200 must reach the
    handler; a smaller number means something below the policy is still
    applying a ceiling of its own

127 is the probe's own number, reproduced from the test side.

**B, the name/value length ceilings restored in place:**

    Expected: <2>
      Actual: <0>

Both the 200-character name and the 16 KiB value silently dropped.

**One of the three new assertions is NOT a witness and says so in the file.**
"Past the policy ceiling the caller is refused" passes with the ceiling restored
too, because the truncated 128 plus the system headers still exceeds 128, so it
raises there for a different reason. It is labelled a contract guard. A test that
passes on both sides proves nothing about the defect, and the canary is what
found that out.

## Gate

`melos run analyze` clean over 21 packages plus rpc_dart_wasm. `test:unit`
SUCCESS over 14 packages, `rpc_dart` 1663 passed 1 skipped. `format:check` and
`license:check` SUCCESS. In the package: `analyze lib test` clean.

**Four tests in `test/contracts/context_header_caps_test.dart` went red, and they
were not stale — they were a prior round's deliberate decision.** `f876d602`
(2026-09-02) made these very caps effective across `withAdditionalHeaders`, the
builder and `merge`, all three of which had been restarting the tally; its commit
states the trade it chose: *"the symptom was a confusing ArgumentError at send
time instead of a bounded context at build time"*.

So this round reverses that choice, and only after re-measuring its sentence
(L-13). The send-time symptom is no longer an anonymous `ArgumentError`: it is
`RpcMetadataViolation: Invalid argument: Too many metadata headers: 205 > 128`,
which names the count, the limit and the field, and carries INVALID_ARGUMENT
instead of being redacted to INTERNAL — a type introduced after `f876d602`, which
removed the premise without anyone re-reading the decision that rested on it.

The test file was rewritten, not deleted. Its count and byte assertions stood
only on the caps and are inverted; what it was really protecting — that the
builder path and the one-shot path AGREE, that `merge` keeps the union, that an
add cannot evict an existing header — is kept, and its history is in the file's
header so the reversal is not silent.

**I found that file by running the suite, not by looking**: the pre-fix grep for
tests pinning 128 covered two files in `test/core/` and the file is in
`test/contracts/`. L-12 on the axis of DIRECTORY.

**The web target: both of this round's files pass alone under `-p node`** (6/6
and 5/5). Run together they hit round 445's `ENETDOWN` again, which is the
machine's loopback and appears only once a second node process starts.

## Not fixed

**Where the caller learns of the overflow moved from build time to send time**,
and that is a real loss for a context built far from its call site. It is the
trade `f876d602` made in the other direction. Not filed as a lead, because the
alternative that keeps both — a build-time bound sourced from a policy — needs
`RpcContext` to see one, and it is constructed before any transport exists. If
the owner wants build-time loudness back, the shape is a settable default policy,
which is a new API and their call.

## Links

- RPC-25 — one value, two homes, and the second unreachable
- P-100 — does raising `maxHeaders` raise anything
- B-72 — closed by this round
- `f876d602` — the decision reversed here, and the sentence it rested on
- L-12 (the class was counted on the wrong axis — directory), L-13 (re-measure
  the sentence a decision was taken on)
- Witness: `test/core/context_header_size_is_the_policys_test.dart`
- Rewritten: `test/contracts/context_header_caps_test.dart`
