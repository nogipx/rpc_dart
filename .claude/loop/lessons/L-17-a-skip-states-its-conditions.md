---
round: 398
class: process
cost: 5 runs of an arm that could not see the defect — 4 solo, 1 workspace gate per http2 version — all green, and a conclusion stated out loud ("the upgrade is not what changed it") that was wrong by 10 of 10. The probe that settled it in 2 runs is named in the lead's own frontmatter. Caught by the owner in one sentence: *maybe the test is wrong?*
paths: [packages/transport/rpc_dart_http2/test/request_sink_error_over_http2_test.dart, .claude/loop/backlog/B-53-an-http2-reset-racing-responses-kills-the-connection.md]
commit: 007d7004
status: active
---

# L-17 — a skip states its CONDITIONS, not just its reason

## The rule

A `skip:` line says a test fails. It almost always also says WHERE — under
load, on a platform, against a version, after a specific other thing. That
clause is a hypothesis about conditions, and reproducing the test's PASS under
different conditions measures nothing at all.

So before unskipping something as evidence: find the conditions its reason names
and reproduce those. If they cannot be reproduced, the result is
INCONCLUSIVE — not "fixed".

## What happened

B-53 was skipped with *"an abort on a stream we have not half-closed,
mid-response"*. The lead one directory over spelled out the condition in full:
the case is *"clean run alone, and not enough under load: the witness still
failed inside the workspace gate"*.

Round 398 unskipped it and ran it **alone**, twice, on two http2 versions. Green
four times. Reported as "the upgrade is not what changed it". Then the workspace
gate, green on both versions too — so the test had gone quiet on the old version
as well and could not settle the question in either direction.

The defect was real and the upgrade did fix it. P-73, the deterministic probe,
reads **10 of 10 DEAD on 2.3.1 against 10 of 10 clean on 3.1.0**.

## The second half, which is the cheaper rule

**The lead's frontmatter names its probe.** B-53 carries
`probe: .../abort_kills_the_connection.dart`. That field exists so a later round
does not have to guess which artefact answers the question, and it points at a
deterministic eight-arm matrix rather than a load-dependent test.

> Reach for the PROBE the lead names before the test that happens to be nearby.
> A test is shaped by the suite it lives in; a probe is shaped by the question.

Related: [[L-15]] — an arm that arrives in the single state that works reads
exactly like a clean one. This is that lesson for a whole test file rather than
one arm, and the tell is different: not a void observation, but a documented
precondition nobody re-read.
