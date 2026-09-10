---
round: 306
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-23
bench: none
commit: yes
---

# Round 306 — the mandate finishes in one language

## Target

The rest of `rpc_http2_caller_transport.dart` — the 71 Cyrillic lines and the
narrative round 305 named and left, from `releaseStreamId` to `close()`.

305 deferred them on a stated rule (a batch that cannot be read whole is being
skimmed) and named the check that would settle it. This round runs that check to
zero, which is the only way a deferral like that stays honest.

## Hypothesis

Nothing new — the remaining region holds the same two things as the first half:
Russian diagnostics, and measurement tables recording runs on a tree that has
moved.

## Before

```
                          comments  total   Cyrillic lines
rpc_http2_caller_transport     647   1961               71
```

## Mechanism

No new shape; this is the completion of one. The remaining Cyrillic was all
operator-facing or maintainer-facing diagnostics — `'Освобождение stream'`,
`'Отправка данных для stream'`, `'Ожидание завершения N активных потоков'`,
`'Закрытие HTTP/2 транспорта'` — plus an `assert` message and the inline
comments through `_setupStreamListener`, the incoming handlers, `reconnect` and
`close`.

Two of them were worth more than a translation, because the Russian was carrying
the load-bearing fact:

- `releaseStreamId`'s block explains why release must NOT write to the stream —
  an empty `sendData(endStream: true)` on a half-closed stream is a CONNECTION
  error in HTTP/2, and package:http2 throws it asynchronously so the try/catch
  around it never sees it. That is the invariant a future edit would destroy,
  and it was half in Russian.
- `close()`'s block explains why every remaining stream is aborted INCLUDING the
  half-closed ones, and why RST_STREAM is legal there where DATA is not.

Both are now English and state the rule rather than the history.

The tables that went with them: the 4-of-40 connection-termination count, the
websocket-vs-http2 close timings (5 ms against 1734 ms), the 600 ms
handler-inside-the-wait result, the 104 ms / 20.4 s finish() hang, the GOAWAY
retry counts, and the MAX_CONCURRENT_STREAMS saturation transcript.

## After

```
                          comments  total   Cyrillic lines
rpc_http2_caller_transport     574   1888                0
```

**-73 comment lines**, and the file's Cyrillic count is **0**.

Checked one level up, which is what makes it a result rather than a claim:

```
grep -rlE "[А-Яа-яЁё]" packages/core/*/lib packages/transport/*/lib
  -> no matches
```

**Every `lib/` in core and in all six transport packages is now English.** What
Cyrillic remains under `packages/transport` is in `test/`, `example/` and a
`.gitignore` — outside the doc-comment mandate, and outside `lib/` in every case.

Package: 1501/4541 -> **1428/4468, 32.0%**, from 36.5% when round 303 opened it.

## Canary

The analyzer over lib plus 199 passing tests show the code still compiles and
behaves, not that a comment is right.

The language half has the witness 303 established and this round drove to zero:
`grep -cE "[А-Яа-яЁё]"` on the file read 97 at the start of 305, 71 at its end,
and 0 now.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1303/1303.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 199 passed.

## Not fixed

**The doc half of the owner's mandate is complete**: all five named packages
swept, every `lib/` in one language, zero code lines changed across 300-306.

**The other two halves are not, and this is the round that says so plainly.**
The mandate asked for three things — rewrite the doc comments, draw the
boundaries and clean the API, and put the code and abstractions in order. Only
the first is done:

- **Boundaries / API.** RPC-24 (public by omission) was applied to core in
  289-292 and never to a transport. Round 300 spot-checked the websocket barrel
  and found it clean, which is not a sweep. The four transport packages' export
  surfaces have not been audited.
- **Code and abstractions.** Untouched by design: every round 293-306 reports
  "zero code lines changed". Nothing here has looked for a duplicated
  abstraction, a leaking type or a seam in the wrong place.

Neither is blocked; both are simply the next work, and each is a lens of its own
rather than more of RPC-23.

## Links

RPC-23 (`applied:` gains 306), and this closes it for the mandate — 14 rounds,
293-306, across six packages.

The language finding that began as a side-observation in 303 is now a completed
sweep with a one-line detector, and B-30 carries the 22 files outside the
mandate that the same detector found.
