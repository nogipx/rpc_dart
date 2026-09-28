---
round: 473
commit: 0aad1385
paths: [packages/transport/rpc_dart_wasm/ios/rpc_dart_wasm.podspec, packages/transport/rpc_dart_wasm/ios/Resources/PrivacyInfo.xcprivacy]
scope: [rpc_dart_wasm]
---

# C-55 — an SPM-enabled app already gets this plugin

Bench: none — the instrument is a BUILT app and the device suite's exit status,
which is what B-03 demands as evidence.

> **Scope**: Flutter 3.38.3, an iOS simulator, the example host app. It says
> nothing about a future Flutter that drops the CocoaPods fallback, which is the
> only thing left of the lead's concern.

## The claim that was checked

B-03: *"An app that has turned on Swift Package Manager support in Flutter does
not get the plugin at all."*

## The numbers

The same suite, on the same simulator, varying only
`flutter config --enable-swift-package-manager`:

```
SPM enabled    build log: "Adding Swift Package Manager integration..."
               +26  All tests passed!
CocoaPods      no such line
               +26  All tests passed!
```

**The plugin loads either way.** Flutter's SPM support is ADDITIVE: a plugin with
no `Package.swift` is still resolved through CocoaPods, and the two coexist in one
app. Had the plugin not loaded, every test would have failed on a
`MissingPluginException` at the first `loadRuntime`.

## Control

The build log line is the control for the variable itself — `Adding Swift Package
Manager integration...` appears in one arm and not the other, so the flag
demonstrably took effect rather than being ignored.

The suite is the control for the outcome: 26 tests that all exercise the plugin,
so "it loaded" is not an inference from a green build.

## The other half, also checked on a built app

B-03's second constraint is that the privacy manifest must reach the build. It
does, from the podspec's `resource_bundles` alone:

```
Runner.app/Frameworks/rpc_dart_wasm.framework/
    rpc_dart_wasm_privacy.bundle/PrivacyInfo.xcprivacy
```

So the `resource_bundles` fix an earlier round made still holds on a real build,
and with no `Package.swift` there is no second manifest path to keep in sync —
which was the lead's stated difficulty.

## What this does NOT settle

Whether to add `Package.swift` anyway, for the day Flutter stops falling back.
That is now a forward-compatibility choice with no present benefit, not a fix for
a live breakage, and it is the owner's.

One practical note for whoever takes it: the Flutter SPM layout puts sources at
`ios/<plugin>/Sources/<plugin>/`, so it needs a file MOVE — and `mv`, `git mv`
and `rm` are all outside this project's allowlist. It is not a change a round can
make under rule zero.
