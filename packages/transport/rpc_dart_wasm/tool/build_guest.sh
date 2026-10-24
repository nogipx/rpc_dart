#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
#
# Compiles example/wasm_guest/main.dart to WASM, and the same guest to
# JavaScript, and drops them where the example app can load them as assets: the
# WASM one for iOS and Android, the JS one for macOS (RpcFlutterWasmBridge.loadJs).
#
# Built rather than committed on purpose: a checked-in .wasm goes stale the
# moment core changes, and the device test would then be reporting on a guest
# nobody is shipping -- the same trap pubspec_overrides.yaml exists to avoid.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="$(dirname "$HERE")/example"
OUT="$EXAMPLE/assets"

mkdir -p "$OUT"
cd "$EXAMPLE"

fvm dart compile wasm wasm_guest/main.dart -o "$OUT/guest.wasm"

# dart2wasm also emits guest.mjs beside the output; both are loaded at runtime.
ls -l "$OUT/guest.wasm" "$OUT/guest.mjs"

# The same guest under dart2js: its dart:js_interop code is the same.
fvm dart compile js -O2 wasm_guest/main.dart -o "$OUT/guest.js"
ls -l "$OUT/guest.js"
