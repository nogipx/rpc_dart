<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.2.0

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.1.3

**Fixes (audit):**
- `RpcGzipCodec` now validates the compression `level` (0..9). An out-of-range level (e.g. `10`) made archive's deflate silently emit a gzip frame with NO compressed payload (its range throw is commented out upstream) — silently corrupt output. The constructor and `register({int level})` now `assert` the range for dev builds, and `compress` defensively `level.clamp(0, 9)` at the encode site so release / dart2js builds (where asserts are stripped) cannot emit a corrupt frame. Added a regression test: out-of-range throws in dev, and boundary levels always produce a valid gzip that decompresses back to the original.

## 0.1.2

**Features:**
- `RpcGzipCodec` now accepts a compression `level` (0..9, default `6` matching the previous archive default, so existing callers are unchanged). It is forwarded to `GZipEncoder.encodeBytes(level: ...)`. Constants `RpcGzipCodec.fastestLevel` (1), `RpcGzipCodec.defaultLevel` (6), and `RpcGzipCodec.bestLevel` (9) are provided. `RpcGzipCodec.register({int level, int maxDecompressedSize})` forwards both options.
- Optional decompression-bomb guard via `maxDecompressedSize` (default unlimited). The gzip ISIZE trailer is checked before allocating, so oversized declared output is rejected with a `FormatException` at no cost for in-limit payloads.

**Memory:**
- Removed the redundant `Uint8List.fromList(...)` copies in `compress`/`decompress`: `GZipEncoder.encodeBytes` and `GZipDecoder.decodeBytes` already return a `Uint8List` on every platform. The archive 4.x streaming API (`encodeStream`/`decodeStream` with `OutputMemoryStream`) was evaluated but does not reduce peak memory for the `Uint8List -> Uint8List` interface (output still accumulates into one contiguous buffer) and would bypass the integrity guards on web, so the validated whole-buffer path is kept. The integrity checks (header + CRC32 + ISIZE trailer) are unchanged.

## 0.1.1

**Fixes (audit):**
- `RpcGzipCodec.decompress` now verifies integrity instead of silently accepting corrupt input. It validates the gzip magic/compression method, decodes with `verify: true`, and independently checks the gzip trailer (CRC32 + ISIZE) against the decoded output. Malformed, truncated, or non-gzip input now throws `FormatException` consistently across VM, dart2js, and Wasm -- previously the web decoder silently returned garbage/empty bytes.

## 0.1.0

- Initial release: `RpcGzipCodec` cross-platform gzip codec (native/web/JS/Wasm via the `archive` package).
