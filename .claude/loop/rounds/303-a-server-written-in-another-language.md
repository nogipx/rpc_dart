---
round: 303
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-23
bench: none
commit: yes
---

# Round 303 — a server written in another language

## Target

`rpc_dart_http2`, the last package of the owner's mandate — and the largest
transport by a wide margin: **1762 comment lines in 4826**, more than websocket,
http and isolate put together.

Taken as two rounds rather than one. This round sweeps `rpc_http2_server.dart`,
`rpc_http2_common.dart` and `http2_header_block_guard.dart` (1740 lines); the two
transports are 3070 lines between them and get round 304. The lens's unit is a
batch of files, not the whole package regardless of size, and a batch that
cannot be read whole in one pass is not being swept — it is being skimmed.

## Hypothesis

The adjacency shape appears again, in the fourth package running.

## Before

Probe: `grep -rcE "^[[:space:]]*//"` and `grep -rc ""` over
`packages/transport/rpc_dart_http2/lib`.

```
                            comments  total      %
rpc_http2_caller_transport       675   1989   33.9   <- round 304
rpc_http2_server                 409    957   42.7
rpc_http2_responder_transport    349   1081   32.3   <- round 304
rpc_http2_common                 239    558   42.8
http2_header_block_guard          83    225   36.9
barrels                            7     16

package lib total               1762   4826   36.5
this round's three files         731   1740   42.0
```

## Mechanism

**Declaration fusion, the seventh, in the largest file.** `_releaseEndpoint`'s
doc — *"Drops a disconnected connection's endpoint and closes it"*, with the
one-leak-per-client-disconnect warning under it — ran straight into `_drain`'s
doc with no declaration between them. Everything attached to `_drain`, and
`_releaseEndpoint`, declared 140 lines below, had **no doc at all**. Seven
instances, five packages.

**The finding that was not on the lens: this server is written in RUSSIAN.**
The root `CLAUDE.md` states the rule outright —

> - English for code, comments, and logs.

— and `rpc_http2_server.dart` broke it end to end: the class doc, the
constructor's whole parameter list, `createWithContracts`, the getters, `start`,
`stop`, `_handleConnection`, and **every log string the server emits at
runtime**. This is rule one applied to prose: the repo's stated style and the
code diverge, so it is a defect, and it is fixed in the same round that found
it. All of it is now English, including the operator-facing log lines.

Also cut, by the established rule: the 200-socket preface table, the keepalive
endpoint/contract tables, the MAX_CONCURRENT_STREAMS 143x table, the ALPN
openssl transcript, the flow-control 39x table, the `_notify` stack trace, the
CONTINUATION-flood RSS figures, and the TCP_NODELAY read-back — all of them
records of one run on a tree that has moved.

Two smaller repairs the sweep surfaced:

- **A typo in a public doc**: `ensureGrpcFrame` was documented as
  *"Gárrantees that [data] is a valid gRPC frame"* — a misspelling carrying an
  accent that does not belong to any word in either language.
- **Paragraph fusion**, three times in `guardHttp2HeaderBlock`'s doc:
  `[skipConnectionPreface]`, `[onGoaway]` and `[onPrefaceComplete]` were each
  swallowed into the paragraph above them, so three parameter descriptions
  rendered as a continuation of the prose about CONTINUATION floods.

## After

```
                            comments  total      %
rpc_http2_server                 298    845   35.3
rpc_http2_common                 217    536   40.5
http2_header_block_guard          80    222   36.0

this round's three files         595   1603   37.1
package lib total               1626   4689   34.7
```

**-136 comment lines** across the three files. Zero code lines changed.

Cyrillic in the swept files: **0**, checked with
`grep -nE "[А-Яа-яЁё]"`.

## Canary

The analyzer over lib plus 199 passing tests show the code still compiles and
behaves, not that a comment is right.

The language half has a real witness and it is not the analyzer:
`grep -rlE "[А-Яа-яЁё]" packages/*/*/lib` listed `rpc_http2_server.dart` before
and does not list it after. That check is what found B-30.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS after one reformat: shortening a Russian log
string to English changed how the line wrapped, and the gate caught it. Worth
noting as evidence the gate is doing its job on a prose-only round.
`melos run license:check` — compliant, 1299/1299.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 199 passed.

## Not fixed

`rpc_http2_caller_transport` (675) and `rpc_http2_responder_transport` (349)
are round 304, together with the Cyrillic in both.

**B-30 filed**: the same language check found 25 lib files in Russian across the
repo, and 22 of them are in `rpc_data`, `rpc_blob`, `rpc_data_sqlite` and
`rpc_notify` — packages the owner's mandate does not name. `rpc_data` holds 16,
in the contract, the models and the repository interfaces, on a package that is
published. Not swept here because choosing that scope is the owner's call, not
the round's; one of the 16 is generated and needs its source fixed instead.

## Links

RPC-23 (`applied:` gains 303). Seventh declaration fusion, fifth package.
B-30 (new).

What 303 adds to the lens: a doc sweep is the pass that reads every comment in a
file, so it is also the only pass that can see a comment written in the wrong
LANGUAGE, misspelled, or otherwise wrong in a way no gate reads. The three
non-narrative repairs here — the fusion, the typo, the language — were all found
by the same reading, and none of them is comment bloat.
