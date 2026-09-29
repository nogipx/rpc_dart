---
refines: U-03
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/core/rpc_dart_generator/lib/**]
applies: the repository has packages outside the pub workspace
breaks: "wrong result: a green gate with the package broken, because what was checked is the published core rather than the one about to ship."
applied: [220, 226, 269, 270, 344, 470, 471, 472, 473, 476, 477, 481]
status: confirmed (round 220)
---

# RPC-11 — A package outside the workspace

## Shape

`rpc_dart_wasm` and `rpc_dart_generator` take no part in the common run, so the
ordinary gate never sees them.

## Detector

The workspace member list against the list of directories under `packages/`.

## Ask

Does this package resolve core from local source or from the published version?

## Evidence

Without `pubspec_overrides.yaml` the wasm target silently tests the PUBLISHED
core.

**Rounds 269-270 got this backwards and that is the sharpest thing the lens
carries.** 269 read `rpc_dart_wasm/pubspec.yaml`, found `rpc_dart '>=5.0.0
<6.0.0'` and no `dependency_overrides`, and wrote into `config.md` that
`test:wasm` validates the published core. `pubspec_overrides.yaml` is pub's own
override mechanism, does not appear in `pubspec.yaml`, and points core at
`../../core/rpc_dart` — grepping the one says nothing about the other. The
detector's "Ask" is answerable only from pub's RESOLUTION output, never from a
manifest. The real blind spot is the inverse and smaller: wasm is never tested
against an OLDER published 5.x, which its constraint allows.

Round 220 ran the detector. `melos list` gives 21, `packages/` holds 22, and the
difference is `rpc_dart_wasm`. The gap is wider than "not in the test run":

    scripts mentioning wasm      test:wasm, analyze:native, test:wasm:device,
                                 publish:dry, publish:release, tag:release
    scripts NOT mentioning it    analyze, format:check, test, test:unit

`test:wasm` runs `flutter test`, which does not analyse; `analyze:native` covers
Swift and Kotlin only. So the package's DART source is analysed by nothing and
format-checked by nothing, `melos run prepare` included. Run directly it is
clean — `No issues found!`, 18 files unchanged — so the hole costs nothing
today. `../checked/C-22-wasm-is-outside-every-gate-script.md`,
`../backlog/archive/B-19-close-the-gate-over-wasm.md`.

> **A compensating script is not the same as a covered package.** The three wasm
> scripts read like compensation and cover the native halves and the Dart tests;
> what nobody had checked is which of the ordinary gate's jobs they replace.
> Enumerate the gate's jobs, then ask which the compensation actually does.

## Round 470 — a compensating script nobody RUNS covers nothing at all

The section above asks which of the gate's jobs the compensation does. 470 is the
prior question: **is it run?** `melos run test:wasm:device` exists, is documented,
and had never been executed on Android. Its first run:

```
+23 ~2 -1   Some tests failed.
```

A test that had been wrong since round 416 — expecting a `StateError` the library
had stopped throwing — sat green-by-absence for fifty-four rounds, because
nothing ever asked it.

> **For a script outside the gate, the first question is not what it covers but
> when it last ran.** A gate entry that cannot fail is a known shape (round 348);
> a gate entry nobody invokes is worse, because its existence is cited as
> coverage in the very documents that explain why the package is excluded.

And the reason it went unrun for so long is worth separating from the reason it
was red:

> **A blocker recorded in a lead ages like any other claim.** Three leads shared
> one sentence — *"`xcrun simctl` is outside the agent's allowlist"* — written
> once in round 357 and copied forward. It is false; `simctl` runs. The genuine
> obstacle was different (simulator data missing from disk), fixable by one
> command, and pointed at a different person. L-13 applies to blockers, not only
> to findings.

`../rounds/470-the-device-suite-ran-on-android.md`.

### Round 471 — one unrun suite is an instance; the EXCLUSION LIST is the class

470 fixed a suite. 471 asked how many there are, and the answer is the gate's own
exclusion list — which no round had ever read as a population:

```
config.md, excluded from test:unit    *_postgres, *_minio, the SQLCipher test
CLAUDE.md, excluded from every test*  rpc_dart_generator (build_test)
outside the workspace                 rpc_dart_wasm (its own scripts)
```

The second reachable member, run for the first time: `rpc_blob_sqlite` at
`+30 -7`, same `StateError`-versus-typed-exception shape as the wasm one.

> **A gate's exclusion list is a list of places a sweep did not reach.** When a
> round changes something in ~80 places, the packages it verified are the ones
> the gate runs; the excluded ones took the edit and never took the check. Read
> the exclusion list as the population BEFORE deciding a cross-package change is
> complete.

And the reason this one hid for 55 rounds is a second, sharper thing:

> **An exclusion's stated REASON can be narrower than the exclusion.**
> `config.md` excludes the sqlite packages for the SQLCipher native lib. The
> suite runs; the seven failures are not that test. So the whole package sat
> outside the gate on the strength of one test's requirement, and nobody read the
> gap between the reason and the effect. Check what an exclusion actually excludes
> against what it says it is for.

`../rounds/471-the-other-suite-nobody-runs.md`,
`../backlog/archive/B-92-round-416-went-stale-in-the-suites-nobody-runs.md`.

### Round 472 — the device arrived, and the LEAD was what failed

Three rounds on this lens in a row, and the third is the one worth remembering.
The device that B-38 waited thirteen rounds for finally booted; the fix was
reapplied in full and type-checked; and the witness the lead itself designed
turned out unable to see the defect:

```
with the fix (retry + report)           +27  All tests passed!
CANARY: no retry, give up on failure 1  +27  All tests passed!
CONTROL: the ORIGINAL recv loop         +27  All tests passed!
```

> **A lead that names its own witness has done half the round's thinking, and
> that half needs checking too.** B-38's sentence was *"reachable from inside the
> guest, which is what makes a witness possible at all"* — true about
> REACHABILITY and false about SUFFICIENCY. A supersede replaces the pending task
> with one that is then answered, so the failure it induces is transient by
> construction. Reaching a failure path is not the same as making its
> CONSEQUENCE observable.

> **Run the control BEFORE believing a green fix, especially on a device.** Each
> of these runs costs five minutes, which is exactly the pressure that makes a
> single green run look like enough. The fix's own run and the canary were both
> green; only the third — the original code — showed that none of them meant
> anything.

The outcome is the rule this project already holds: the fix was **reverted**
rather than shipped on `analyze:native` alone. A test that passes on broken code
converts an open question into a false answer, which is worse than the silence it
was meant to replace.

`../rounds/472-the-witness-b-38-designed-cannot-see-it.md`.

### Round 473 — an excluded package's leads go stale in a second way

470 found a suite nobody ran. 471 found the class. 472 found a lead whose witness
design was wrong. 473 is the fourth shape and the cheapest: a lead about the
package's INTEGRATION with its host toolchain, resting on a claim about that
toolchain's behaviour, which nobody could check because nobody could build.

```
SPM enabled    "Adding Swift Package Manager integration..."   +26  passed
CocoaPods      no such line                                    +26  passed
```

B-03 said an SPM-enabled app *"does not get the plugin at all"*. It does:
Flutter's SPM support is additive, and a plugin with no `Package.swift` still
resolves through CocoaPods.

> **A package outside the gate accumulates leads about its ENVIRONMENT, and those
> age faster than leads about code.** A claim about the repository can be
> re-checked by reading; a claim about what Xcode, CocoaPods or the Flutter tool
> does needs a build, and the package that cannot be built is exactly where such
> claims pile up unchecked. Four rounds here, three refuted premises.

> **When the variable is a toolchain FLAG, the build log is the control.**
> `Adding Swift Package Manager integration...` in one arm and not the other is
> what separates "SPM works" from "the setting was ignored". Two identical green
> runs prove nothing on their own.

`../rounds/473-spm-already-gets-the-plugin.md`,
`../checked/C-55-spm-already-gets-the-plugin.md`.

### Round 476 — an exclusion inherited by ASSOCIATION, and one that outlived its cause

The first round on this lens to put a package back INSIDE the gate, and the two
sqlite packages show two different ways an exclusion goes bad.

```
rpc_blob_sqlite   excluded with no reason of its own    +30 -7  ->  +37, now in the gate
rpc_data_sqlite   excluded for a cause since fixed      +45 -1  ->  +46, still out
```

> **An exclusion list is inherited by NAME SIMILARITY more readily than by
> reason.** `rpc_blob_sqlite` has no cipher test; the comment explaining the
> sqlite special case is entirely about `rpc_data_sqlite`. It sat outside the
> gate for a requirement that was never its own, and that is where round 416's
> sweep went stale unseen.

> **And an exclusion outlives its cause silently.** `rpc_data_sqlite`'s reason —
> the `user_defines` declaration having no effect — is fixed: the block is at the
> workspace root now and `sql_cipher_integration_test` PASSES. What keeps that
> package out today is something the comment never said: the test asserts
> availability with no skip, so it would fail for a missing toolchain rather than
> a defect. Re-deriving why an exclusion still holds is a different job from
> reading why it was added.

Method note the round paid for, and it is the cheaper half of L-15:

> **Run a suspicious failure ALONE before believing its message.** The one
> failure that looked like a real defect — `Adapter is closed` on a checksum test
> — said `Chunk checksum mismatch` in isolation. It was a cascade from an earlier
> failure in the same suite, and one command told the difference.

`../rounds/476-the-exclusion-that-belonged-to-a-sibling.md`.

### Round 477 — the whole exclusion list, and where the damage actually was

Seven rounds on this lens; this is the one that finished the count.

```
rpc_blob_sqlite      +37   2 stale assertions + 1 test bug   JOINED the gate
rpc_data_sqlite      +46   1 stale assertion                 excluded for CI
rpc_blob_minio       +23   1 stale assertion
rpc_data_postgres    +20   clean
rpc_notify_postgres   +9   clean
rpc_notify_redis     +13   clean
rpc_dart_generator     —   structurally unrunnable
```

> **Being outside the gate is not by itself what rots a suite — being outside it
> for a reason nobody re-reads is.** Four of six had no staleness at all. The two
> that did are exactly the two whose exclusion had drifted from its stated cause,
> so they had been out longest and nobody was looking. The service suites, whose
> exclusion has a real current reason, were fine.

And the round's own false blocker, which is the third this session:

> **Before recording that a dependency is unavailable, ask what is already
> LOCAL.** Round 471 wrote "the blocker is registry credentials" on the strength
> of a failed `docker run` and a failed `docker pull` — both of which go to the
> registry by construction and neither of which inspects the cache. `docker
> images` listed every image needed. A command that can only fail one way proves
> nothing when it fails.

`../rounds/477-every-excluded-suite-run.md`.
