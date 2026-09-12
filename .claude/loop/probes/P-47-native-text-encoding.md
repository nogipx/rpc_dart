---
file: packages/transport/rpc_dart_wasm/.dart_tool/probe/utf8_from_native_test.dart
round: 355
commit: 60281abc
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
status: valid
---

# P-47 — what reaches Dart when native sends non-ASCII text

Pushes text onto the bridge's `console` and `died` channels encoded the way the
plugins encode it — `utf8.encode`, matching `data(using: .utf8)` and
`toByteArray(Charsets.UTF_8)` — and prints what Dart hands back. Run with
`fvm flutter test .dart_tool/probe/utf8_from_native_test.dart`; add an arm by
adding a string.

## Measures

Characters SENT against characters ARRIVED, with the byte count beside them.
The character count is the sharp one: on a byte-per-character read the arrived
count equals the BYTE count, so the two columns identify the failure mode rather
than merely showing it is wrong.

## Control

One variable: whether the payload is ASCII. The ASCII arm is the control — for
ASCII, UTF-8 and a byte-per-character read agree exactly, which is why every
existing test passes and why the suite's shared helper builds its payload with
`text.codeUnits`.

```
arm                sent          arrived   text
ascii (control)    22 ch / 22 B  22 ch     I:hello from the guest
cyrillic           17 ch / 30 B  30 ch     I:Ð¿ÑÐ¸Ð²ÐµÑ Ð¸Ð· Ð³Ð¾ÑÑÑ    <- before
emoji               9 ch / 11 B  11 ch     I:done ð                     <- before
accents            19 ch / 22 B  22 ch     I:fÃ¼r spÃ¤ter, naÃ¯ve       <- before
cyrillic           17 ch / 30 B  17 ch     I:привет из гостя             <- after
emoji               9 ch / 11 B   9 ch     I:done 😀                     <- after
accents            19 ch / 22 B  19 ch     I:für später, naïve           <- after
```

The control reads `22 ch -> 22 ch` on both sides of the fix, which is what makes
the other rows mean something: the decoder changed only what was broken.
