## 0.1.1

**Fixes (audit):**
- `RpcGzipCodec.decompress` now verifies integrity instead of silently accepting corrupt input. It validates the gzip magic/compression method, decodes with `verify: true`, and independently checks the gzip trailer (CRC32 + ISIZE) against the decoded output. Malformed, truncated, or non-gzip input now throws `FormatException` consistently across VM, dart2js, and Wasm -- previously the web decoder silently returned garbage/empty bytes.

## 0.1.0

- Initial release: `RpcGzipCodec` cross-platform gzip codec (native/web/JS/Wasm via the `archive` package).
