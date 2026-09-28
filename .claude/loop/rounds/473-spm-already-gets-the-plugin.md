---
round: 473
verdict: CLEAN
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the instrument is a BUILT app and the device suite's exit status, which is the evidence this lead demands
commit: yes
---

# Round 473 — an SPM app already gets the plugin

## Target

B-03, which round 472 unblocked by getting the simulator running. Its decision is
*"add `Package.swift` now, not when SPM becomes the Flutter default"*, and it
rests on one sentence:

> An app that has turned on Swift Package Manager support in Flutter does not get
> the plugin at all.

Three leads this session have turned on a sentence nobody re-measured. This one
is measurable in two runs, and the lead itself names the evidence: a BUILT app,
CocoaPods as the control, SPM as the arm.

## Hypothesis

If Flutter's SPM support is additive rather than exclusive, a plugin without
`Package.swift` still resolves through CocoaPods and nothing is broken today.

## Before

```
flutter config                enable-swift-package-manager: (not set)
ios/rpc_dart_wasm.podspec     source_files, resource_bundles, Flutter dep
ios/                          no Package.swift
```

## The measurement

Same suite, same simulator, one flag varied:

```
SPM enabled    build log: "Adding Swift Package Manager integration..."
               +26  All tests passed!
CocoaPods      no such line
               +26  All tests passed!
```

**Refuted.** The plugin loads with SPM on. Had it not, all 26 tests would have
failed at the first `loadRuntime` with a `MissingPluginException` — the suite does
nothing else.

## Mechanism

None. No code changed, and the flag was restored to its original value.

## After

Unchanged.

## Canary

The build-log line is the round's variation: `Adding Swift Package Manager
integration...` appears in one arm and not the other, so the flag demonstrably
took effect. Without it, two identical green runs would be equally consistent
with the setting having been ignored.

## The second constraint, checked on the built app

B-03's other requirement is that the privacy manifest reaches the build. From the
podspec's `resource_bundles` alone:

```
Runner.app/Frameworks/rpc_dart_wasm.framework/
    rpc_dart_wasm_privacy.bundle/PrivacyInfo.xcprivacy
```

So the earlier `resource_bundles` fix holds on a real build, and with no
`Package.swift` there is no second manifest path to keep in sync — which was the
lead's stated difficulty with doing this at all.

## A side effect worth knowing about

**Enabling SPM makes Flutter MUTATE the example's Xcode project, and disabling it
does not undo that.** After both runs the tree carried 40 added lines across
`Runner.xcodeproj/project.pbxproj` and `Runner.xcscheme` — the SPM build
pre-action and its package reference. Reverted here.

Anyone repeating this measurement should check `git status` afterwards: the
scaffolding is plausible-looking, survives turning the flag back off, and would
commit silently as if it had been chosen.

## Gate

`melos run test:wasm:device` green on iOS in both arms (`+26`). No source
changed, so the workspace gate is untouched; the global Flutter setting was put
back to `false`, its state before the round.

## Not fixed

**`Package.swift` is not added, and the reason has changed.** It is no longer a
fix for a live breakage — there is none — but a forward-compatibility choice for
the day Flutter stops falling back to CocoaPods. That is the owner's call, and it
should be re-decided against this measurement rather than the refuted sentence.

One practical constraint for whoever takes it: Flutter's SPM layout puts sources
at `ios/<plugin>/Sources/<plugin>/`, so it needs a file MOVE — and `mv`, `git mv`
and `rm` are all outside this project's allowlist. Not a change a round can make
under rule zero.

## Links

- RPC-11 — the package outside the gate, fourth round running
- L-13 — a decision inherits the sentence it was taken on. This is the third
  blocker or premise re-measured this session and the third that was false
- C-55, B-03
