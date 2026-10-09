---
round: 783
commit: 2f469332
paths: [pubspec.lock, packages/transport/rpc_dart_wasm/pubspec.lock]
scope: published advisories in OSV (ecosystem Pub) for the exact locked versions; not the Dart SDK, not unpublished defects in dependencies
---

# C-68 — the lockfiles have no known advisories

Both lockfiles were sent to `https://api.osv.dev/v1/querybatch` as
name, version pairs, ecosystem `Pub`: the workspace's 106 packages and
`rpc_dart_wasm`'s standalone 61. No package had an advisory. The SDK floor
is `>=3.10.0` in every package, above CVE-2022-0451's fix (Dart 2.16:
credentials on a cross-origin redirect).

Re-open when a lockfile changes; the check costs one request per lockfile.

## Control

The same endpoint asked for `http` `0.13.2` (ecosystem Pub) returns
`GHSA-4rgh-jx4f-qfcq`, so the query can see a Pub advisory when one exists.
