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

## Commit conventions (REQUIRED)

Conventional Commits are the convention — they keep history readable and signal
the version bump (see types below). The CHANGELOG and version are **hand-written
at release time** (versioning is manual; there is no `melos version` — see
"Release flow"), so the commit type/scope is guidance for the human, not an
automation input. Format:

```
type(scope): short imperative subject

optional body explaining the why.

BREAKING CHANGE: describe the break (or use the `!` form below).
```

- **type** signals which version bump to make by hand at release:
  - `feat` → minor (new capability)
  - `fix` / `perf` → patch
  - breaking → **major**: either `feat(scope)!: ...` / `fix(scope)!: ...`, or a
    `BREAKING CHANGE:` footer.
  - `refactor`, `docs`, `test`, `build`, `ci`, `chore` → no version bump (still
    worth a changelog line where relevant).
- **scope** = the affected package name, e.g. `rpc_dart`, `rpc_dart_http2`,
  `rpc_dart_generator`. Use the bare core name `rpc_dart` for core changes.
- **Keep a commit to one package** when possible (one changed package =
  unambiguous changelog/version). Split unrelated cross-package changes into
  separate commits.
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

**Every package under `packages/` is public** — all 22 are on pub.dev, and none
sets `publish_to:` (the default is pub.dev). Only the root `pubspec.yaml` is
`publish_to: none`. A new package is therefore public by default: before adding
one, make sure it has no `path:` deps on siblings (the pub workspace already
links them — see "Workspace resolution") and no dependency on anything unpublished.

`rpc_dart_wasm` is not a pub-workspace member, so `melos publish` cannot see it;
both `publish:dry` and `publish:release` run `flutter pub publish` for it
explicitly right after the melos step, so one command still covers everything.
Because that step sits outside melos it also misses melos' skip-if-already-
published filter, so both scripts ask pub.dev whether the current wasm version
exists and skip it if so — otherwise every release that does not bump wasm dies
on `Version X already exists`, after the other packages have gone out.

### Release flow (do this EVERY release, in order)

0. **`melos run prepare` — MANDATORY first, and it must be green.** This is the
   gate: it syncs licenses, formats, runs `analyze` (strict: `--fatal-infos
   --fatal-warnings`, lib AND test), `reuse lint`, and `test:unit` across the
   whole workspace (so it catches lint/test breakage that a `dart analyze lib`
   or a single-package test run misses — e.g. a behavior change in `rpc_dart`
   that breaks a transport's tests). If it finds anything: fix, commit, re-run.
   Do NOT proceed to publish until `prepare` exits 0. (Skipping this once shipped
   a `curly_braces` lint into a published rpc_dart.)
1. **Manual versioning — do NOT use `melos version`.** For each changed public
   package: bump its `version:` in the pubspec (patch/minor/major per the commit
   types since the last release) and write the CHANGELOG entry by hand (newest
   section on top, terse, why-focused). Do NOT tag here — `publish:release` tags.
2. Commit the release (just commits; tags are created at publish): `git push`.
3. `melos run publish:dry` — must validate with 0 warnings (a dirty git tree
   shows up as a warning here, so commit first).
4. Publish: `fvm dart pub login` then `melos run publish:release`. This publishes
   the public packages to pub.dev, then hands off to `tag:release`, which
   **auto-tags** each public package at its current pubspec version
   (`<pkg>-<version>`, idempotent) and pushes commits + tags. pub.dev
   tag-triggered "Automated publishing" is NOT used. Publishing is
   irreversible — confirm the version (esp. major bumps) before this step.
5. If `publish:release` aborts partway, run **`melos run tag:release`** to
   finish. The upload is irreversible but everything after it is idempotent, so
   re-running the whole release is wrong — it would try to re-publish what
   already landed. Tags name where a version lives, so tagging separately is
   well-defined. (Do not hand-craft the tags: the format has to match.)

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