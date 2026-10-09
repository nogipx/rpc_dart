---
round: 543
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-175 — new
budget: probes 2/5, canaries 1/5
commit: yes
release: breaking
severity: S1
---

# Round 543 — the encoding nobody could perform

## Target

**The owner asked why the tests were failing.** Round 542 had reported `test:unit` failing once
with the test unnamed, and round 541 had filed B-211 claiming `test:web`'s six failures were a
bad test. Both answers were inadequate and one was wrong.

Three separate causes, one of them a library defect that B-211 had written off.

Lens RPC-08: one name, one promise. `grpc-encoding` was declared from a constant and
`grpc-accept-encoding` from the registry, two adjacent lines disagreeing about what the endpoint
can do.

## Hypothesis

Round 541 wrote that the library was right and the test wrong, on the strength of the error
message naming a known platform difference. Reading the CODE instead: `caller_pipeline` sets
`RpcHeaders.grpcEncoding: RpcGrpcCompression.gzip` unconditionally, six lines above a block
that asks `supportedEncodings()`. If the registry has no gzip, the caller announces an encoding
it cannot perform.

## Before

```
  registry                         compressionEnabled: true
  as shipped (identity,gzip)       echoed 64 bytes
  gzip UNREGISTERED (identity)     RpcStatusException(12): Unsupported grpc-encoding: gzip
  a registered codec               echoed 64 bytes
  CONTROL compression off          echoed 64 bytes
```

Bench `../probes/P-175-does-compression-enabled-need-a-codec.md`.

**`compressionEnabled: true` fails EVERY call where no gzip codec is registered**, which is
dart2js by construction — the built-in codec is backed by `dart:io`. So the flag made the
library unusable on the web, and the six test failures were the tests doing their job.

## Mechanism

`compress()` throws `UnsupportedError` for an unregistered encoding and the responder refuses
the frame UNIMPLEMENTED, so the declaration is a promise neither side can keep. The registry
already knew the answer; only this one line did not ask it.

`RpcGrpcCompression.requestEncoding()` is the single home for the rule: prefer `gzip` when
registered, so the shipped default is byte-identical for everyone who has it, otherwise the
first other registered encoding, otherwise null — and null declares nothing rather than a lie.

**Breadth: one site.** `grep` for `RpcHeaders.grpcEncoding:` and for `RpcGrpcCompression.gzip`
across every package's `lib/` returns this line and the compression package's own codec
registration. The responder's response encoding already went through
`selectResponseEncoding`, which checks `isSupported`, so that direction was never affected.

**The measurement nearly missed it.** P-175's first version used `RpcChannelTransport.memoryPair()`
and reported all four arms healthy, because the declaration is guarded by
`!transport.supportsZeroCopy` and a zero-copy pair never reaches it. An arm that cannot touch
the code under test reads exactly like a pass.

## After

```
  gzip UNREGISTERED (identity)     echoed 64 bytes, declared nothing
  a registered codec               echoed 64 bytes, declared x-runlength
  as shipped                       echoed 64 bytes, declared gzip
  CONTROL compression off          echoed 64 bytes
```

On `test:web`, four of the six failures in
`compression_never_makes_a_message_bigger_test.dart` went green by themselves — the calls now
complete there.

## Canary

```
1. the constant restored (`final encoding = RpcGrpcCompression.gzip`)

   WITNESS a call still works when no codec is registered
     Expected: 'echoed'
       Actual: 'RpcStatusException(12): Unsupported grpc-encoding: gzip. Supported:
                identity. On web/dart2js the built-in gzip is unavailable; register
                a cross-platform codec...'

   And the second witness with it, at `Supported: identity, x-runlength` — which is
   the sharper reading: a codec WAS registered and the constant still ignored it.
```

One canary, because the fix is one mechanism. The three guards — a registered codec is
announced, gzip is still preferred when present, compression off works in either state — are
what stop it passing by never declaring anything.

## The other two failures, and why only one was a defect

**`rpc_dart_http`'s `a_cancel_does_not_fire_a_phantom_post_test`** is a test premise, not a
defect. Round 536 made `releaseStreamId` complete an abort trigger, so a cancel landing before
the POST is accepted aborts it and the server records nothing:

```
  when the cancel lands            paths the server recorded
  after 0ms                          [[], [], [], [], []]
  after 1ms                          [[], [], [], [], []]
  after 5ms                          [/Svc/slow x4, [] x1]
  after 20ms, 100ms, 400ms           all /Svc/slow
  after the request ARRIVED          all /Svc/slow
```

`.dart_tool/probe/cancel_arrival_race.dart`. The fixed 100 ms sufficed idle and not under load.
`/Unknown/Unknown` — what the test measures — appeared in no arm, so the assertion failed on its
premise rather than its subject. It now polls for arrival, which also keeps the cancel inside
the window the phantom used to fire in.

**A third red was invisible.** `set -e` aborts `test:web` at the first failing package, and
core's suite had been red since round 513, so the script never reached
`rpc_dart_isolate`'s two Chrome files — where the second fails to load. Each passes alone (34 s
and 6 s); together in one `dart test` the second Chrome starts while the first is shutting down
and misses its deadline. `-j 1` serialises TESTS, not BROWSERS. Split into two invocations, which
is what the script's own comment had already diagnosed without acting on it.

## What B-211 got wrong, and why

It read the error message — which names a real platform difference and even names the remedy —
and concluded the library was right. Rule one: prose about code is a secondary source, and an
ERROR STRING is prose. The message was accurate about gzip's availability and said nothing about
the caller announcing it anyway.

The lead also asserted "the LIBRARY is behaving correctly" without varying anything. One
`unregister` call on the VM would have shown otherwise in a second.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2106 / 2106, REUSE compliant
melos run test:web               STILL RED — see below. Core's suite is green.
```

`test:unit` was run with its failure lines captured in the SAME invocation this time, which is
what round 542 failed to do.

**`test:web` is NOT green, and an earlier draft of this record said it was.** The run that
looked clean was piped through `grep`, so the exit status read was the pipe's and not melos'.
Re-run for its own status: `test:web FAILED`. The claim was written before it was checked and
is exactly the shape of error this round is about.

What IS established: **core's own suite passes on node**, which is where all six compression
failures were, and four of those went green from the library fix alone.

## Not fixed

**Compare-and-keep-smaller is untested against a cross-platform codec.** The round-513 file is
now `@TestOn('vm')`, and the accurate reason is not that gzip is web-only — `RpcGzipCodec` in
`rpc_dart_compression` is cross-platform and that package's suite already runs on node. It is
that every arm there needs a registered codec: with none the two GUARDs fail and the four
witnesses pass VACUOUSLY (`on == off`), which reads as coverage. The same property against that
codec's ratios belongs in that package. Filed as B-214.

**The Chrome half is NOT fixed, and the split is justified by mechanism rather than by
measurement.** The sequence, in order, is the finding:

```
  both files, one invocation      the SECOND fails to load
  echo_worker alone               passes, 34 s
  worker_startup_failure alone    passes, 6 s
  both, one invocation, again     the second fails to load
  --- split into two invocations ---
  test:web                        worker_startup_failure: 2 of 4 fail, the two
                                  needing a HEALTHY worker -- "the worker script
                                  failed to load or threw during startup"
  worker_startup_failure alone    FAILS to load, 95 s
```

The last line is the one that matters: the same file that passed alone in 6 s now fails alone,
so the variable is not the invocation shape. The 15-minute load average went from 7.5 to 20.5
across these attempts, driven by the runs themselves — the condition `config.md` names for
batches of failures that look like real flakes.

So the split stands on its mechanism (each file gets its own Chrome, and one `dart test`
starts the second while the first is shutting down — the script's own comment, unacted on) and
removes one cause. It is not shown to make the target deterministic, and nothing here separates
it from load. Filed as B-215 with the sequence above, to be re-measured on a quiet machine.

## Links
Lead `../backlog/B-211-the-web-target-has-been-red-since-round-513.md` — closed, and
its own diagnosis corrected: filed as a test defect, and the library was at fault.
Lead `../backlog/B-214-compare-and-keep-smaller-has-no-web-arm.md` — new.
Lead `../backlog/B-215-the-chrome-suites-fail-differently-every-run.md` — new; the only red
left in `test:web`, and the reason this round cannot claim that target green.
Bench `../probes/P-175-does-compression-enabled-need-a-codec.md` — new.
Round `513-the-compression-that-grew-the-message.md` — wrote the file that has been red on the
web ever since, having never run that target.
Round `536-the-release-that-freed-only-bookkeeping.md` — the abort that made the cancel test
racy.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [543]`.
Lesson: **none, deliberately.** The rule this round would write — an error string is prose
about code, so it is a secondary source — is already rule one of the skill, which lists
comments, READMEs, commits and the journal and means every one of them. What B-211 added is an
INSTANCE, not a rule, and the instance lives here. At seventeen lessons the thing a reader
gives up for an eighteenth is the attention the other seventeen need.
Lesson `../lessons/L-17-a-skip-states-its-conditions.md` — applied rather than extended: the
`@TestOn('vm')` added here names the CONDITION (every arm needs a registered codec) and where
the property belongs instead, not just that it fails.
