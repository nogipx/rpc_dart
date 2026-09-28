---
status: decided by owner (round 415)
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_wasm/ios/**]
probe: —
reason: decided — add `Package.swift` now rather than waiting for SPM to become the Flutter default; the privacy manifest must be declared in BOTH manifests and the evidence is a BUILT app
---

# B-03 — wasm: no `Package.swift`

## The iOS blocker is real but NOT what the other leads say (round 470)

`xcrun simctl` is not outside the allowlist — that sentence, shared with B-38 and
B-85, was written in round 357 and never re-measured. It runs, and reports the
actual obstacle: every registered simulator's data directory is missing from
disk (`Unable to boot device because it cannot be located on disk`). One command
in the owner's environment fixes it — `xcrun simctl erase <udid>` or recreating
the device in Xcode — and round 470 did not run it, because erasing a simulator
destroys its contents.

This lead needs iOS specifically (`pod install`, then `test:wasm:device` twice —
CocoaPods as the control, then SPM), so it stays blocked. Android does not
substitute.

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

**Taken: add it now.** Not deferred until SPM becomes the Flutter default — the
cost of adding it is the same either way, and nothing in a round's ordinary work
would detect the day the default flips.

The two constraints above are the whole of the difficulty, and both make this a
DEVICE round rather than a source edit:

- the privacy manifest goes in BOTH manifests, or the second path brings back
  the `resource_bundles` defect already caught once;
- the evidence is a BUILT app. A manifest in the repository proves nothing, and
  `pod install` must be re-run before rebuilding.

So this cannot be closed by `analyze:native` — it needs `melos run
test:wasm:device` on iOS, twice: once under CocoaPods (the control, proving the
existing path still works) and once with SPM enabled.
