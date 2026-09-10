---
file: packages/core/rpc_dart_grpc_reflection/.dart_tool/probe/hostile_reflection_requests.dart
round: 284
commit: e7cd2d9b
paths: [packages/core/rpc_dart_grpc_reflection/lib/**]
status: valid
---

# P-33 — seventeen hostile reflection requests

P-28's shape aimed at the other hand-rolled parser in this repository. Malformed
protobuf through `processRequestForTest`, the entry point the reflection method
uses, with the outcomes sorted into the three kinds that matter differently:
a response, a leaked `Exception`, a leaked `Error`.

Add a row to extend it; `_lenField(field, payload)` builds a length-delimited
field so a request can contradict itself.

## Measures

Which KIND of outcome each case produces, and the response length — the second
is what caught the echo behaviour that no per-case verdict would have shown.

## Control

A well-formed `list_services` request through the identical call.

```
CONTROL  well-formed list_services   answered 5 bytes
17 hostile cases                     17 answered, 0 Exceptions, 0 Errors
of which  a 1 MiB symbol name        answered 1048629 bytes
```

> **Print the response SIZE, not just the verdict.** Every row here "passed",
> and the only interesting one is visible solely as a number: a 1 MiB symbol
> name comes back as a 1 MiB response, because the reflection proto requires
> `original_request` in every reply. A bench that printed `ok` per case would
> have reported seventeen clean rows and missed it.
