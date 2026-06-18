<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart — repository guide

Transport-agnostic RPC framework for Dart. This is a **monorepo** managed with
**Dart pub workspaces + melos 7**.

## Layout

- `packages/core/*` — core library (`rpc_dart`) + framework, log, generator,
  grpc_reflection, opentelemetry, compression.
- `packages/transport/*` — transports: http, http2, isolate, websocket, wasm.
- `packages/data/*`, `packages/notify/*`, `packages/blob/*` — higher layers.
- Root `pubspec.yaml` declares the pub `workspace:` and the `melos:` config.

## Toolchain — ALWAYS use fvm

The SDK is pinned via fvm (Flutter 3.38.3 / Dart 3.10.1). Never call bare
`dart`/`flutter`.

- `fvm dart ...`, `fvm flutter ...`
- Run melos as `fvm dart run melos <cmd>`.

### Workspace resolution

All packages resolve each other from **local source** via the pub workspace —
do NOT add `dependency_overrides` or `path:` deps to sibling packages to "link"
them; the workspace already does that. After changing dependencies run
`fvm dart pub get` at the **repo root** (resolves the whole workspace).

`rpc_dart_wasm` is intentionally **NOT** a workspace member (it is the only
Flutter package; including it would pin the whole lockfile to the Flutter SDK's
transitive deps). It resolves standalone — test it separately.

## Common commands

One-time setup (puts `melos` on PATH; its `exec:` scripts re-invoke `melos`, so
it must be a global executable, not `dart run melos`):

```
fvm dart pub global activate melos     # once; ensure ~/.pub-cache/bin is on PATH
fvm dart pub get                        # resolve the workspace (run at repo root)
```

Then run the scripts (each spawns `fvm dart`/`fvm flutter`, so the pinned SDK is
used for the actual work):

```
melos run analyze        # analyze all packages (lib+test, strict)
melos run test           # tests (excludes generator, see below)
melos run test:unit      # tests, no service-dependent packages
melos run test:wasm      # the Flutter wasm package (separate)
melos run test:web       # dart2js/node web regression guard
melos run format:check   # formatting gate
melos run publish:dry    # validate publishable packages
melos exec --scope=rpc_dart_http2 -- fvm dart test   # one package
melos list --category transport                      # group filter
```

Categories: `core`, `transport`, `data`, `notify`, `blob`.

Before committing: `melos run analyze` and the relevant `melos run test` must be
green. Do not edit generated files (`*.g.dart`, `*.freezed.dart`) by hand — run
the generator.

## Commit conventions (REQUIRED — drives melos changelogs)

`melos version` generates each package's CHANGELOG and version bump from
**Conventional Commits**. A malformed commit produces a wrong/missing changelog
entry. Format:

```
type(scope): short imperative subject

optional body explaining the why.

BREAKING CHANGE: describe the break (or use the `!` form below).
```

- **type** drives the version bump:
  - `feat` → minor (new capability)
  - `fix` / `perf` → patch
  - breaking → **major**: either `feat(scope)!: ...` / `fix(scope)!: ...`, or a
    `BREAKING CHANGE:` footer.
  - `refactor`, `docs`, `test`, `build`, `ci`, `chore` → no version bump (still
    shown in changelog where relevant).
- **scope** = the affected package name, e.g. `rpc_dart`, `rpc_dart_http2`,
  `rpc_dart_generator`. Use the bare core name `rpc_dart` for core changes.
- **Attribution is by changed files**, not by the scope text: melos assigns a
  commit to whichever package directories it touches. So **keep a commit to one
  package** when possible; a commit that edits several packages bumps all of
  them. Split unrelated cross-package changes into separate commits.
- Subject: imperative, lower-case, no trailing period, <= ~72 chars.

Examples:
```
fix(rpc_dart): cancel stale subscription on stream-id reuse
feat(rpc_dart_http2): honor grpc-timeout on the server
fix(rpc_dart)!: require printable-ASCII metadata header values

BREAKING CHANGE: non-ASCII metadata values now throw ArgumentError;
use a -bin key for binary data.
```

## Publishing

Only **`rpc_dart`** and **`rpc_dart_generator`** are public (`publish_to:
pub.dev`). Every other package is `publish_to: none`. Do not flip a package to
public without checking it has no `path:` deps and no dependency on a private
package.

Release flow:
1. `fvm dart run melos version` — bumps versions + CHANGELOGs from commits,
   updates inter-package constraints, creates per-package git tags
   (`<package>-vX.Y.Z`).
2. `fvm dart run melos run publish:dry` — validate.
3. Publish: either `fvm dart pub login` then `melos run publish:release`, or
   pub.dev "Automated publishing" triggered by the git tag (preferred).

## Known caveats

- **generator**: `rpc_dart_generator` build_test golden tests are incompatible
  with pub-workspace layout (no per-member `package_config.json`). The `test`
  script excludes it; run `melos run test:generator` standalone.
- **infra tests**: `*_postgres`, `*_minio`, and the SQLCipher test in the sqlite
  packages need running services / a cipher-enabled native lib. Use
  `melos run test:unit` to skip them.
- **web is a real target** (dart2js / Wasm). Guard against dart2js pitfalls
  (async* cancel, int > 2^53, clock/Random); run `melos run test:web` for
  web-relevant changes.

## Style

- No emoji anywhere (code, comments, commits, docs).
- Never add `Co-Authored-By` or self-references to commits.
- English for code, comments, and logs.