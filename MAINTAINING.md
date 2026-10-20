# Maintaining rpc_dart

The procedures `CLAUDE.md` points at: publishing, the release flow, and the two
checks the ordinary gate cannot run (the generator's tests and the wasm
plugin's native code).

## Publishing

**Every package under `packages/` is public** — all 22 are on pub.dev, and none
sets `publish_to:` (the default is pub.dev). Only the root `pubspec.yaml` is
`publish_to: none`. A new package is therefore public by default: before adding
one, make sure it has no `path:` deps on siblings (the pub workspace already
links them — see "Workspace resolution" in `CLAUDE.md`) and no dependency on
anything unpublished.

The one exception is `packages/test/rpc_dart_conformance`, which is
`publish_to: none` on purpose: it is the transport conformance matrix (the
owner's invariants, `.claude/loop/invariants/`, run against every transport),
it holds tests and no library, and it depends on every transport. `melos
publish` and `tag:release` skip private packages, so it is never published or
tagged; it still runs in `test:unit` (category `conformance`).

`rpc_dart_wasm` is not a pub-workspace member, so `melos publish` cannot see it;
both `publish:dry` and `publish:release` run `flutter pub publish` for it
explicitly right after the melos step, so one command still covers everything.
Because that step sits outside melos it also misses melos' skip-if-already-
published filter, so both scripts ask pub.dev whether the current wasm version
exists and skip it if so — otherwise every release that does not bump wasm dies
on `Version X already exists`, after the other packages have gone out.

## Release flow (do this EVERY release, in order)

0. **`melos run prepare` — MANDATORY first, and it must be green.** This is the
   gate: it syncs licenses, formats, runs `analyze` (strict: `--fatal-infos
   --fatal-warnings`, lib AND test), `reuse lint`, and `test:unit` across the
   whole workspace (so it catches lint/test breakage that a `dart analyze lib`
   or a single-package test run misses — e.g. a behavior change in `rpc_dart`
   that breaks a transport's tests). If it finds anything: fix, commit, re-run.
   Do NOT proceed to publish until `prepare` exits 0.
0b. **`rpc_dart`'s public API is frozen through 7.x, and `prepare` checks it.**
   `melos run api:check` compares it with `docs/api/rpc_dart.txt`, a sorted
   line per public declaration. A removed or changed line breaks someone and
   is not allowed in 7.x; an added line is a minor release. After reviewing a
   change, `melos run api:update` rewrites the snapshot: commit it with the
   change. It needs `dart_apitool` once:
   `fvm dart pub global activate dart_apitool 0.23.2`. The wire format is
   pinned the same way by `test/core/the_wire_format_is_pinned_test.dart`: a
   failure there needs a new `RpcChannelFrame.protocolVersion`, not a new
   literal.
1. **Manual versioning — do NOT use `melos version`.** For each changed public
   package: bump its `version:` in the pubspec (patch/minor/major per the commit
   types since the last release) and write the CHANGELOG entry by hand (newest
   section on top, terse, why-focused). Do NOT tag here — `publish:release` tags.
   `rpc_dart_log` also states its version in `lib/src/version.dart`, which it
   reports to MCP clients; a test fails until the two match.
1b. **Raise the `rpc_dart` floor in every package that started using a NEW core
   API.** `melos run bump:rpc_dart` does it. This is invisible to every gate:
   the pub workspace always resolves core from local source, so a transport that
   calls an API added this cycle analyses and tests green while still declaring
   `rpc_dart: '>=5.0.0 <6.0.0'` — and a user who resolves the old core gets a
   compile error the moment they add the new transport.
   The check needs no network: `git show <release-tag>:<core file>` is the
   published source, so grep it for the symbols the dependent uses.
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

## The generator's tests

`rpc_dart_generator`'s golden tests are `build_test`, which needs a per-package
`.dart_tool/package_config.json` — and a pub workspace centralises that at the
root. So they are incompatible with this layout and every `test*` script
excludes the package. **There is NO `melos run test:generator`.** Every one of
the generator's four test files imports `build_test`, so nothing there can be
run from inside the workspace at all. The only way is the manual one the root
`pubspec.yaml` documents next to the `test` script: temporarily remove
`resolution: workspace` from the generator's pubspec AND its entry from the
root `workspace:` list, `fvm dart pub get` in the package, run, then put both
back. Its `lib/` is still covered by `melos run analyze`.

## The wasm plugin's native code

`rpc_dart_wasm` ships a Swift and a Kotlin plugin, and `melos run test:wasm`
exercises the Dart bridge alone. Neither `analyze` nor `test` compiles a line of
either, so a native change ships unverified unless you run:

- **`melos run analyze:native`** — type-checks both against the real frameworks
  (Flutter engine, WebKit, androidx.javascriptengine). Needs Xcode for the
  Swift half; for the Kotlin half a `kotlinc` (Android Studio's counts), an
  Android SDK platform, and a gradle module cache warmed by any previous
  Flutter Android build. Missing toolchains are SKIPs, and a run that checked
  NOTHING exits **2** so it can never read as a pass.
- **`melos run test:wasm:device`** — actually RUNS it, via
  `packages/transport/rpc_dart_wasm/example`, a host app whose only purpose is
  to give `flutter build` something to compile the plugin into. Boot a
  simulator/emulator first. ~1 min, mostly the build; deliberately NOT part of
  the ordinary gate. **Run it on BOTH platforms** — the two boot scripts are
  separate strings in separate languages, so a fix to one is never a fix to
  the other, and some cases only exist on one (`Platform.isIOS` skips are
  explained in the test).

Two build constraints the example encodes, both of which fail the build
outright rather than degrading: `minSdk = 26` (androidx.javascriptengine's
floor) and `platform :ios, '15.0'` in the Podfile (the podspec's). And no
`.license` sidecar may exist under Android `res/` — the resource compiler
rejects any file there that is not `.xml` or `.png`, so those paths are
annotated in `REUSE.toml` instead.

The levels find different things and the order is strict — reading <
compiling < running. Reading shipped a dead-runtime report through
`finishBoot`, a no-op after boot. Compiling would not have caught the 30 s boot
stall the first device run found, and running is what showed that on iOS a page
loaded with `baseURL: nil` cannot fetch its own module at all.
