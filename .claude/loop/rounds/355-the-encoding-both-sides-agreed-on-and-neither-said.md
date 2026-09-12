---
round: 355
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-47 — new
commit: yes
---

# Round 355 — the encoding both sides agreed on and neither checked

## Target

The owner's 6.0.0 review list, P0 item 5.

RPC-06, widened. Its Shape is *"the defect lives in Swift or Kotlin, where Dart
greps never look"*, and round 348 established the reason: two scripts in two
languages, and one says nothing about the other. This defect is in neither
language. It is in the CONTRACT between them, and that is a third place no
single-language gate can see — `analyze:native` checks Swift and Kotlin,
`dart analyze` checks Dart, and all three pass.

**Scope counted before the fix.** The class is *bytes produced by a UTF-8
encoder and read by something that is not a UTF-8 decoder*. All 14
`String.fromCharCodes` call sites in every package's `lib/`:

```
site                                            bytes are            verdict
rpc_http2_common.dart (7 sites)                 HTTP/2 header octets  correct
  header names and values, :path, :method, :status
  kept verbatim on purpose -- a `-bin` value is base64 and
  decoding it here would double-process true binary. Documented.
rpc_http2_caller_transport.dart:606             an HTTP status line   correct
s3_blob_storage_adapter.dart:965                its own base62 alphabet  correct
webdav_blob_repository.dart:720                 its own base62 alphabet  correct
rpc_flutter_wasm_bridge.dart:113 (console)      UTF-8 from native     WRONG
rpc_flutter_wasm_bridge.dart:190 (_reasonOf)    UTF-8 from native     WRONG
```

Two of fourteen. The other twelve are ASCII by protocol or built from an
alphabet the code defines itself, so `fromCharCodes` is right there — in the
http2 case deliberately and with a stated reason.

## Hypothesis

Both plugins encode with UTF-8 and say so in one line each —
`reason.data(using: .utf8)` and `log.data(using: .utf8)` in
`RpcDartWasmPlugin.swift:581,629`; `reason.toByteArray(Charsets.UTF_8)` and
`log.toByteArray(Charsets.UTF_8)` in `RpcDartWasmPlugin.kt:425,493`. Nothing on
the Dart side names an encoding at all. If `String.fromCharCodes` is a
byte-per-character reinterpretation rather than a decoder, then every non-ASCII
character crossing either channel arrives as one mojibake character per byte,
and no test can see it because the suite's shared helper sends `text.codeUnits`.

## Before

```
arm                sent          arrived   text
ascii (control)    22 ch / 22 B  22 ch     I:hello from the guest
cyrillic           17 ch / 30 B  30 ch     I:Ð¿ÑÐ¸Ð²ÐµÑ Ð¸Ð· Ð³Ð¾ÑÑÑ
emoji               9 ch / 11 B  11 ch     I:done ð
accents            19 ch / 22 B  22 ch     I:fÃ¼r spÃ¤ter, naÃ¯ve
died reason -> RpcStatusException(14): WASM runtime rt-1 died:
               Ð³Ð¾ÑÑÑ ÑÐ¿Ð°Ð»: Ð½ÐµÑ Ð¿Ð°Ð¼ÑÑÐ¸
```

Probe: `packages/transport/rpc_dart_wasm/.dart_tool/probe/utf8_from_native_test.dart`.

**The arrived count equals the BYTE count in every broken arm.** That is the
signature of one character per byte, and it is why the probe prints both: the
pair identifies the failure mode, where a single "it looks wrong" would not.

## Mechanism

`String.fromCharCodes` maps each byte to the code unit of the same value. For
code points below 128 that is identical to UTF-8, so the ASCII arm agrees
exactly — and every existing test sends ASCII, through a helper that builds its
payload with `text.codeUnits`. The operation cannot throw and cannot fail, so
there was nothing to catch.

## After

```
arm                sent          arrived   text
ascii (control)    22 ch / 22 B  22 ch     I:hello from the guest
cyrillic           17 ch / 30 B  17 ch     I:привет из гостя
emoji               9 ch / 11 B   9 ch     I:done 😀
accents            19 ch / 22 B  19 ch     I:für später, naïve
died reason -> RpcStatusException(14): WASM runtime rt-1 died:
               гость упал: нет памяти
```

One `_decodeNativeText` helper at both call sites, so there is one place that
names the encoding and it sits next to the two lines of native code that chose
it.

## Canary

Two, because the fix has a decoder and a FLAG, and the flag can be set wrongly.

```
_decodeNativeText -> String.fromCharCodes
  Expected: ['I:привет из гостя, für später, done 😀']
    Actual: ['I:Ð¿ÑÐ¸Ð²ÐµÑ Ð¸Ð· Ð³Ð¾ÑÑÑ, fÃ¼r spÃ¤ter, done ð']
  and: does not contain 'гость упал: нет памяти'

_decodeNativeText -> utf8.decode(bytes)   [allowMalformed dropped]
  FormatException: Unfinished UTF-8 octet sequence (at offset 6)
```

They fail DIFFERENTLY, which is the point of canarying the flag separately: the
first is corruption, the second is a throw inside a platform message handler and
inside the death report — a truncated log line would become a crash, or the
death notice that is the channel's whole purpose would be lost.

The ASCII guard stayed green under the first canary. That is not a bonus: ASCII
being unaffected is exactly why this shipped, so a test that pins it is what
keeps the next decoder change honest.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:wasm` `+44`; `melos run test:unit --no-select` SUCCESS;
`melos run format:check` SUCCESS; `melos run license:check` 1350/1350.

`analyze:native` and `test:wasm:device` were NOT run and did not need to be: no
Swift or Kotlin changed. The plugin's App Store and Play publishability is
untouched — `utf8.decode` adds no API, no permission and no dependency.

## Not fixed

Nothing in this class. The other twelve `fromCharCodes` sites were each read and
are correct where they stand.

## Links

Lens `../lenses/RPC-06-native-plugin-layers.md` (second application; `applies:`
widened from "the native layer" to the contract ACROSS it).
Bench `../probes/P-47-native-text-encoding.md`, new.
Catalog shape U-14 — the signal versus its handling, across a language boundary
rather than between two siblings.
