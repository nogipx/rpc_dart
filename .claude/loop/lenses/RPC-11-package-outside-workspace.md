---
refines: U-03
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/core/rpc_dart_generator/lib/**]
applies: the repository has packages outside the pub workspace
breaks: "wrong result: a green gate with the package broken, because what was checked is the published core rather than the one about to ship."
applied: []
status: confirmed (round 186, off-journal)
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
