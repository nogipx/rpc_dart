<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart — repository guide

Transport-agnostic RPC framework for Dart. This is a **monorepo** managed with
**Dart pub workspaces + melos 7**.

## Layout

- `packages/core/*` — the core library and its companions:
  - `rpc_dart` — contracts, endpoints, streaming, codecs, `RpcContext`,
    errors and resilience, `RpcSecurityPolicy` and flow control, logging,
    the in-memory and channel transports, and the codegen annotations.
    Ships the Agent Skill (see below).
  - `rpc_dart_generator` — `build_runner` generator: an annotated interface
    becomes the caller, the responder base, name constants and codecs. The
    recommended way to define contracts.
  - `rpc_dart_framework` — client/server framework on top: modules, DI,
    lifecycle, graceful shutdown, rate limiting, isolate workers, test harness.
  - `rpc_dart_compression` — compression codecs (gzip), web-compatible.
  - `rpc_dart_grpc_reflection` — gRPC Server Reflection, so grpcurl and
    Postman can discover services.
  - `rpc_dart_log` — remote log collector over WebSocket.
  - `rpc_dart_opentelemetry` — OpenTelemetry tracing, metrics and logs.
- `packages/transport/*` — transports: http, http2, isolate, socket (Unix
  domain and TCP), websocket, wasm.
- `packages/data/*`, `packages/notify/*`, `packages/blob/*` — higher layers.
- `packages/test/rpc_dart_conformance` — the transport conformance matrix
  (test-only, unpublished; see "Publishing").
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

Because `melos exec` only ever sees members, that used to put its Dart source
outside every gate: an unused import planted in its `lib/` left both
`melos run analyze` and `melos run format:check` reporting SUCCESS over 21
packages. `analyze`, `format` and `format:check` are therefore `run:` blocks
that sweep the members and then handle this one package by hand — the shape
`publish:dry` already used. **Its TESTS are still separate** (`melos run
test:wasm`), and so is its native code (`analyze:native`).

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
melos run analyze:native # the wasm plugin's Swift + Kotlin (see below)
melos run test:wasm:device # RUNS that native code; needs a booted device
melos run test:web       # dart2js/node web regression guard
melos run format:check   # formatting gate
melos run check:skills   # shipped Agent Skills: examples compile, frontmatter, links
melos run publish:dry    # validate publishable packages
melos exec --scope=rpc_dart_http2 -- fvm dart test   # one package
melos list --category transport                      # group filter
```

Categories: `core`, `transport`, `data`, `notify`, `blob`, `conformance`.

Before committing: `melos run analyze` and the relevant `melos run test` must be
green. Do not edit generated files (`*.g.dart`, `*.freezed.dart`) by hand — run
the generator.

## Commit conventions (REQUIRED)

Conventional Commits are the convention — they keep history readable and signal
the version bump (see types below). The CHANGELOG and version are **hand-written
at release time** (versioning is manual; there is no `melos version` — see
[MAINTAINING.md](MAINTAINING.md)), so the commit type/scope is guidance for the human, not an
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

**Every package under `packages/` is public** (pub.dev is the default), except
`packages/test/rpc_dart_conformance`, the test-only conformance matrix. So a new
package must have no `path:` deps on siblings and no unpublished dependency.

Releasing is the owner's. The procedure — `melos run prepare` first and green,
manual versions and CHANGELOGs, `bump:rpc_dart`, `publish:dry`,
`publish:release`, `tag:release` to finish an aborted one — is in
[MAINTAINING.md](MAINTAINING.md). Read it in full before any release step.

## Known caveats

- **generator**: its tests are `build_test`, which a pub workspace cannot run,
  so every `test*` script excludes the package and there is NO
  `melos run test:generator`. Its `lib/` is covered by `analyze`. The manual
  way to run the tests is in [MAINTAINING.md](MAINTAINING.md).
- **native code needs its OWN two scripts — the ordinary gate never touches it.**
  A change to `rpc_dart_wasm`'s Swift or Kotlin plugin ships unverified unless
  you run `melos run analyze:native` and `melos run test:wasm:device` on BOTH
  platforms. Toolchains, build constraints and why both levels are needed:
  [MAINTAINING.md](MAINTAINING.md).
- **infra tests**: `*_postgres`, `*_minio`, and the SQLCipher test in the sqlite
  packages need running services / a cipher-enabled native lib. Use
  `melos run test:unit` to skip them.
- **web is a real target** (dart2js / Wasm). Guard against dart2js pitfalls
  (async* cancel, int > 2^53, clock/Random); run `melos run test:web` for
  web-relevant changes.

## Agent Skills shipped with packages

`packages/core/rpc_dart/skills/rpc_dart-core/` is an Agent Skill for USERS of
rpc_dart. `dart pub publish` bundles `skills/`, and users install it with
`dart run skills get`. It is the reference documentation for agents, and it is
read offline at the version the user resolved, so it must match the code
exactly.

**Its scope is the packages under `packages/core/`**, not `rpc_dart` alone.
`rpc_dart` is covered in full. Each companion has one reference covering the
everyday workflow an agent needs, and its README stays the full reference:
`code-generation.md` (`rpc_dart_generator` -- defining contracts by generation
is what the skill recommends), `framework.md`, `compression.md`,
`grpc-reflection.md`, `remote-logging.md` (`rpc_dart_log`) and
`opentelemetry.md`. Their ```dart blocks import the sibling package directly;
`check:skills` resolves it through the workspace.

- Change a public API of any package under `packages/core/` that the skill
  describes, and you update the skill in the same commit. That includes the
  generator's annotations, generated class names and command line.
  `melos run check:skills` (part of `prepare`) compiles every ```dart block. It
  cannot see prose, so a renamed parameter mentioned only in text still slips
  through.
- The ```dart blocks of one file are joined into one library. Write every block
  as top-level code: statements go inside a function, and put imports in the
  block.
- `SKILL.md` must open with `---` frontmatter, so it carries no SPDX header.
  `license:annotate` skips it, and `REUSE.toml`'s `**/*.md` covers it.
- Transport specifics belong in that transport's README, not in the skill.
- A block that needs generated code cannot compile in `check:skills`, which
  has no `build_runner`. Fence it as ```text and check it against real
  generator output by hand (a scratch package under `.dart_tool/probe/`).

## The evidence-loop skill is linked, not copied

`.claude/loop/` — the journal, 350 rounds of it — belongs to this repository and
is in git. The skill that reads it lives in its own repository and is linked in:

```
ln -s <path>/evidence-loop-skill .claude/skills/evidence-loop
```

**The link is gitignored on purpose.** It points outside this tree, so a
committed symlink would be a dangling path in every other clone. After a fresh
clone the skill is simply absent until that command is run; `loop.py` then works
through the link, and `.claude/settings.json` already allows it at that path.

Fix the skill in its own repository, not through the link. An edit made here
lands in the other repository's working tree, where it is easy to commit by
accident into an unrelated change.

## Style

- No emoji anywhere (code, comments, commits, docs).
- Never add `Co-Authored-By` or self-references to commits.
- English for code, comments, and logs.

### Logging — one shape, everywhere

**Hold a non-nullable `LogScope`, resolved once in the initialiser list:**

```dart
final LogScope _log;
MyThing({LogScope? logger}) : _log = logger ?? LogScope.noop;
```

`LogScope.noop` exists for exactly this. A nullable field spreads `?.` and
`?? false` across every call site and makes the guard below read differently in
every file.

**Guard every INTERPOLATING `internal` / `trace` / `debug` call:**

```dart
if (_log.isInternal) {
  _log.internal('Registering method: $methodKey');
}
```

These take a `String`, so an unguarded call builds the message and hands it to a
logger that throws it away — the guard is a bool read. `warning`/`error` are not
guarded: they are rare by construction and there is no `isWarning`.

**A warning that a peer can trigger repeatedly fires ONCE**, behind a bool. A
misbehaving peer misbehaves on every frame, and the interesting fact is that it
happened at all, not how often.

Both halves are witnessable and should be tested that way —
`test/transports/flow_controller_logging_test.dart` is the worked example. Note
the guard cannot be seen from the record stream (a filtered record is discarded
either way); count calls into a `LogScope` subclass instead.