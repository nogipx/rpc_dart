---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-152 — HTTP/1.1 caller: smaller defects and hygiene

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Healthy after close, minified names, dead catch, per-call regexes, redundant type test, unmapped TLS errors, misleading texts, a nullable logger.

## The shape

1. `:588-594` — `reconnect()` reports healthy after `close()`; the doc at `:234`
   says the transport has no reconnect.
2. `:568, 573, 590` — `runtimeType.toString()` as component name, minified on web.
3. `:49-57` — `on FormatException` around `utf8.decode(allowMalformed: true)` can
   never fire; two `RegExp`s compiled per call.
4. `:534` — `error is RpcStatusException || error is RpcException` (the first is
   a subclass); TLS `HandshakeException` is not a `ClientException` and passes
   through with no status.
5. `:309-313` — "Call sendMetadata first" after the request was already fired.
6. `:363-366` vs `:169-177` — "drain before reporting" vs deliberately stopping
   at 8 KiB.
7. `_logger?.isInternal ?? false` throughout — the nullable-logger shape CLAUDE.md
   forbids (`LogScope.noop`).

## Why it matters

Diagnostics and code-shape only.

## Witness a round would build

None.

## Fix sketch

One cleanup commit.

## Owner decision

—
