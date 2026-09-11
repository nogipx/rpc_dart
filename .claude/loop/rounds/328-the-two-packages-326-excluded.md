---
round: 328
verdict: FIXED
packages: [rpc_dart_generator, rpc_dart_wasm]
lens: RPC-26
bench: none
commit: yes
---

# Round 328 — the two packages 326 excluded

## Target

Round 326 put nine packages on the shared analysis floor and named two it left
off with reasons: `rpc_dart_wasm` (not a workspace member, count not taken) and
`rpc_dart_generator` (its `package:lints` include already fails to resolve in
some contexts — "understand that before adding indirection").

Both are in scope: `packages/transport/rpc_dart_wasm` and
`packages/core/rpc_dart_generator`. RPC-26 is 2 rounds, 2 FIXED, so this is the
cheapest remaining application of the best-yielding lens.

## Hypothesis

These two are excluded because they are hard, so they hold the most. And the
generator's resolution failure is a live gate hole: if `dart format` cannot read
its `analysis_options.yaml`, then `formatter: page_width` never applies and the
package is formatted by luck.

## Before

**Both wrong, and the second one is the interesting failure.**

```
rpc_dart_generator, under the shared floor    2 issues
rpc_dart_wasm,      under the shared floor    1 issue
```

Three, against 211 for the other nine and 320 for core. The two packages nobody
had raised are the two cleanest in the repo — all three hits are
`directives_ordering`.

And the gate hole does not exist. Measured by setting `page_width: 100` in the
base and running `dart format --output=none --set-exit-if-changed` on both a
package that resolves and one that does not:

```
rpc_dart_log        (resolves)        9 of 11 files changed
rpc_dart_generator  (does NOT)        1 of 3 files changed
```

The generator reformatted too, so the `formatter:` section reaches it. What
fails to resolve is only `package:lints/...`, which the FORMATTER does not need
and the ANALYSER resolves fine.

## Mechanism

The generator has no per-package `.dart_tool/package_config.json` — the pub
workspace centralises it at the root, the same fact that makes its `build_test`
goldens unrunnable in this layout — and `dart format` does not walk up to find
the root's. So it cannot resolve any `package:` URI in an analysis_options file,
**whichever file names it**: the warning predates the shared floor, was there
when the include sat directly in the generator's own options, and is not fixable
from configuration.

> **Round 326's comment in `analysis_options_base.yaml` was wrong and is
> corrected here.** It said packages include the base by relative path because
> "a relative include always resolves". The relative path does resolve — but it
> chains to a `package:` URI one level down, so the warning survives the change
> that was supposed to explain it. The true reason the relative include is right
> is narrower: everything the formatter needs arrives anyway, and only the half
> the analyser resolves is left unresolvable.

## After

```
melos run analyze     21 packages + rpc_dart_wasm    clean
melos run format:check                               clean
melos run test:unit   14 packages, 0 failures, every count unchanged
```

All 22 packages are now on one floor. Nothing is excluded from it.

## Canary

`Future<void> close()` in `rpc_wasm_transport.dart` narrowed to `Future close()`
— a raw generic, the shape `strict-raw-types` exists for — analysed under both
floors:

```
old floor (lints/recommended, what wasm had)   No issues found!
new floor (the shared one)                     1 issue: strict_raw_type
```

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart` `+1435 ~1`,
`rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`, all unchanged.

## Not fixed

**The generator's `format:check` warning stays**, now with a measured
explanation rather than a guess. It is noise on a path that works: the formatter
gets its settings, the analyser resolves the lints, and only the two together in
one tool fail. Fixing it would mean giving the generator a per-package
`package_config.json`, which the workspace deliberately does not do.

`rpc_dart_wasm`'s native code (Swift, Kotlin) is still outside every floor —
that is RPC-06, never applied, and it needs toolchains this environment may not
have.

B-30's in-scope half — 55 Russian-comment files in `test/` and `example/` across
core and transport, found by the curate after 327 — is untouched.

## Links

RPC-26 (`applied:` gains 328; now 3 rounds, 3 FIXED). What this adds: **a
config that fails to resolve is not necessarily a config that fails to
apply.** Before treating a resolution warning as a hole, change a setting in the
file and check whether the target obeys it — here `page_width` reached the
package whose include was broken, and the hole was imaginary.
