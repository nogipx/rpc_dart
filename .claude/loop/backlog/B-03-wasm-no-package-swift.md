---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_wasm/ios/**]
probe: —
reason: SPM in Flutter 3.38.3 is an optional preview with CocoaPods as the default; the cost right now is zero
---

# B-03 — wasm: no `Package.swift`

An app that has turned on Swift Package Manager support in Flutter does not get
the plugin at all. In 3.38.3 SPM is an optional preview
(`enable-swift-package-manager: (Not set)`) with CocoaPods as the default, so
this is not urgent.

**When it is added: the privacy manifest must be declared in BOTH manifests**,
or the second path brings back the very defect already caught once —
`PrivacyInfo.xcprivacy` was in the package, but the podspec did not declare
`resource_bundles`, so it never reached the build.

**The evidence is a built app, not a source tree**: a manifest in the repository
proves nothing, and `pod install` must be re-run before rebuilding.

The standing requirement about store publishability is in `../config.md`.

## Owner decision

—
