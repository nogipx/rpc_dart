---
status: closed (round 671)
release: changelog
round: 671
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_cors_policy.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b153_cors_claims.dart
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-153 — CORS policy: a process-wide warning flag, duplicate headers, per-response rebuilds, a mutable allow-list

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_starWarningEmitted` is one bool per process (doc says per origin) and falls back to `print`; default allowed headers duplicate the required ones; header lists are rebuilt per response; `allowedOrigins` is not copied, so mutating it later bypasses the `*`+credentials check; origin comparison is case-sensitive (websocket's is not); `preflightMaxAge` null means a preflight almost every call.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_cors_policy.dart:61-62, 100-106, 142, 146-168`.

## Why it matters

The mutable allow-list is a security check that can be undone after construction;
the rest is cost.

## Witness a round would build

Mutate `allowedOrigins` to include `*` after constructing with credentials.

## Fix sketch

Copy and freeze inputs, precompute header strings, default a max-age.

## Outcome (round 671)

FIXED, every claim CONFIRMED. Adding `*` to the caller's list after building a
credentials policy made an evil origin get `*` + credentials; now nothing. A
mixed-case configured origin now matches; 12 Allow-Headers entries with 3
duplicates are now 9; the preflight is cached 600 s by default.
`../rounds/671-a-cors-check-undone-after-construction.md`.

## Owner decision

Round 671: `preflightMaxAge` defaults to 10 minutes.
