---
round: 633
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — the probe reads the message a remote caller receives
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
severity: S1
---

# Round 633 — every subclass is ours

## Target

B-239, from the audit of 2026-10-02: the guides teach APIs that do not exist and
misstate what message a thrown exception produces, and `wireStatusFor`'s own doc
says forwarding an `RpcException` is safe because "every subclass is ours".

## Hypothesis

The doc claims were the lead. The last one is a premise the code relies on:
`wireStatusFor` sends `error.toString()` of any `RpcException`, and the class is
public and not final.

## Before

```
handler throws rpc_data's RpcDataError.internal('Unhandled repository error',
  error: SqliteException(... SELECT ssn FROM users WHERE token='t0p'))
remote caller reads: status 13 "RpcException: Unhandled repository error:
  Exception: SqliteException: no such column 'ssn' in SELECT ssn FROM users
  WHERE token='t0p'"
```

The guides: compiling their snippets fails on `RpcStatus.OK`, `CANCELLED`,
`DEADLINE_EXCEEDED`, `RpcContext.forDomainCall`, `forBusinessOperation`,
`createChain`, `extractDomainMetadata`. Read against the code, three more claims
were false: `RpcTransportRouter` is rpc_notify's, `health()` returns an
`RpcEndpointHealth`, and there is no server-to-client channel for "structured
details via context headers".

## Control

The same handler throwing `RpcStatusException(INTERNAL, 'Unhandled repository
error')`: the caller reads exactly that message.

## Mechanism

RPC-23, the narrative beside the code: "every subclass is ours" was true of the
hierarchy when written and stopped being true the first time a sibling package
extended it. `RpcDataError.toString` appends its cause on purpose, for its own
logs; `DataServiceResponder` strips it with `withoutCause()`, but any other
handler that throws one sent it whole.

## After

`wireStatusFor` sends `error.message`, never `toString()`. The probe now reads
`status 13 "Unhandled repository error"`; a core witness with a subclass whose
`toString` carries a statement reads only the message. The guard that
rpc_dart's own diagnostics still reach the peer passes.

The guides: `error-handling.md` uses the real constants, recommends
`RpcStatusException` for choosing status and message, says what any other
exception becomes (`13 Internal server error`) and why, and points structured
details at `RpcStatusException.details`; `context-and-metadata.md` replaces the
four missing factories with `RpcContextBuilder` and `createChildWith`;
`rpc-lifecycle.md` uses `RpcStatus.ok`. Every name left in the three guides was
grepped in `lib/`.

## Canary

The before line is the same probe against `toString()`.

## Gate

`analyze` and `format` on rpc_dart green, `melos run test:unit` green (exit 0),
rpc_data's suite included.

## Not fixed

A handler's own `RpcException(message)` still sends its message: that is the
thrower's text, as with `RpcStatusException`.

## Links

Lead `../backlog/B-239-the-guides-teach-apis-that-do-not-exist.md` — closed.
Lens `../lenses/RPC-23-the-narrative-beside-the-code.md` — `applied: [..., 633]`.
Test `packages/core/rpc_dart/test/endpoint/handler_error_not_leaked_test.dart`.
