#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
#
# Type-checks the plugin's NATIVE halves.
#
# `flutter test` covers the Dart bridge and nothing else, so a change to
# RpcDartWasmPlugin.swift or RpcDartWasmPlugin.kt ships unverified: this package
# has no example app, and a plugin on its own is not buildable by
# `flutter build`. That gap shipped a real defect -- iOS reported a dead runtime
# through `finishBoot`, a no-op after boot -- which no Dart test could see.
#
# This compiles both files against the REAL frameworks (Flutter engine, WebKit,
# androidx.javascriptengine) using toolchains already on a Flutter dev machine.
# It is a type check, not a test: it proves the code compiles and that every
# platform API it calls exists with the types it uses.
#
# Exit codes: 0 all available checks passed, 1 a check failed, 2 nothing could
# be checked at all (never silently "pass" by checking nothing).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(dirname "$HERE")"
SWIFT_SRC="$PKG/ios/Classes/RpcDartWasmPlugin.swift"
KOTLIN_SRC="$PKG/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt"
WORK="${TMPDIR:-/tmp}/rpc_dart_wasm_check_native"
mkdir -p "$WORK"

ran=0
failed=0

note() { printf '%s\n' "$*"; }
skip() { printf 'SKIP  %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=1; }

# --- Flutter SDK root -------------------------------------------------------
# `flutter` is a shell script inside <sdk>/bin; fvm installs a real SDK too.
flutter_root() {
  local bin
  bin="$(command -v flutter || true)"
  if [[ -z "$bin" ]]; then
    if command -v fvm >/dev/null 2>&1; then
      bin="$(fvm flutter --version >/dev/null 2>&1 && fvm which flutter 2>/dev/null || true)"
    fi
  fi
  [[ -z "$bin" ]] && return 1
  # Resolve symlinks without readlink -f (absent on macOS bash 3).
  while [[ -L "$bin" ]]; do bin="$(cd "$(dirname "$bin")" && pwd)/$(readlink "$bin")"; done
  cd "$(dirname "$bin")/.." && pwd
}

FLUTTER_SDK="$(flutter_root || true)"

# --- iOS: type-check the Swift against Flutter.xcframework ------------------
check_swift() {
  if [[ ! -f "$SWIFT_SRC" ]]; then skip "swift: no source at $SWIFT_SRC"; return; fi
  if ! command -v xcrun >/dev/null 2>&1; then skip "swift: xcrun not found (needs Xcode)"; return; fi

  local fw sdk
  fw="$FLUTTER_SDK/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator"
  if [[ -z "$FLUTTER_SDK" || ! -d "$fw" ]]; then
    skip "swift: Flutter.xcframework not found (run 'flutter precache --ios')"
    return
  fi
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
  if [[ -z "$sdk" ]]; then skip "swift: no iphonesimulator SDK"; return; fi

  ran=1
  if xcrun --sdk iphonesimulator swiftc -typecheck \
      -target arm64-apple-ios15.0-simulator -sdk "$sdk" -F "$fw" "$SWIFT_SRC"; then
    pass "swift: RpcDartWasmPlugin.swift type-checks against Flutter + WebKit"
  else
    fail "swift: RpcDartWasmPlugin.swift does not type-check"
  fi
}

# --- Android: compile the Kotlin against the real Android/Flutter classpath --
# The deps come from build.gradle and live in the gradle module cache, which is
# populated by any prior Flutter Android build. Without one there is nothing to
# compile against and the check skips rather than pretending.
newest() { ls -t 2>/dev/null | head -1; }

find_jar() {
  # $1 = filename to match under the gradle cache; prints the newest hit.
  find "$GRADLE_CACHE" -name "$1" -type f 2>/dev/null | head -1
}

check_kotlin() {
  if [[ ! -f "$KOTLIN_SRC" ]]; then skip "kotlin: no source at $KOTLIN_SRC"; return; fi

  local kotlinc=""
  for c in \
    "$(command -v kotlinc || true)" \
    "/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc" \
    "$HOME/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc/bin/kotlinc"
  do
    [[ -n "$c" && -f "$c" ]] && { kotlinc="$c"; break; }
  done
  if [[ -z "$kotlinc" ]]; then skip "kotlin: no kotlinc (install Kotlin or Android Studio)"; return; fi

  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local android_jar=""
  if [[ -d "$sdk_root/platforms" ]]; then
    # Newest FIRST, but keep walking: a platform directory can exist with no
    # android.jar in it (a partially-removed SDK level), and taking only the
    # highest one made this check skip on a machine that had four usable jars.
    local plat
    while read -r plat; do
      if [[ -f "$sdk_root/platforms/$plat/android.jar" ]]; then
        android_jar="$sdk_root/platforms/$plat/android.jar"
        break
      fi
    done < <(ls "$sdk_root/platforms" 2>/dev/null | sort -Vr)
  fi
  if [[ -z "$android_jar" ]]; then skip "kotlin: no android.jar under $sdk_root"; return; fi

  GRADLE_CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2"
  if [[ ! -d "$GRADLE_CACHE" ]]; then
    skip "kotlin: no gradle module cache; build an Android app once to populate it"
    return
  fi

  local embedding guava cor_guava cor_core cor_android jse_aar
  embedding="$(find_jar 'flutter_embedding_debug-*.jar')"
  guava="$(find_jar 'guava-*-android.jar')"
  cor_guava="$(find_jar 'kotlinx-coroutines-guava-*.jar')"
  cor_core="$(find_jar 'kotlinx-coroutines-core-jvm-*.jar')"
  cor_android="$(find_jar 'kotlinx-coroutines-android-*.jar')"
  jse_aar="$(find "$GRADLE_CACHE" -name 'javascriptengine-*.aar' -type f 2>/dev/null | head -1)"

  local missing=""
  [[ -z "$embedding" ]] && missing="$missing flutter_embedding"
  [[ -z "$guava" ]] && missing="$missing guava"
  [[ -z "$cor_guava" ]] && missing="$missing coroutines-guava"
  [[ -z "$cor_core" ]] && missing="$missing coroutines-core"
  [[ -z "$cor_android" ]] && missing="$missing coroutines-android"
  [[ -z "$jse_aar" ]] && missing="$missing javascriptengine"
  if [[ -n "$missing" ]]; then
    skip "kotlin: gradle cache is missing:$missing"
    return
  fi

  # An .aar is a zip; the classes are in classes.jar.
  local jse_dir="$WORK/jse"
  mkdir -p "$jse_dir"
  if ! (cd "$jse_dir" && unzip -o -q "$jse_aar" classes.jar); then
    skip "kotlin: could not unpack $jse_aar"
    return
  fi

  local cp="$android_jar:$embedding:$jse_dir/classes.jar:$guava:$cor_guava:$cor_core:$cor_android"

  # Android Studio ships kotlinc without the executable bit.
  local runner=(); [[ -x "$kotlinc" ]] || runner=(/bin/sh)

  ran=1
  if [[ -z "${JAVA_HOME:-}" ]]; then
    for j in \
      "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
      "$HOME/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    do
      [[ -x "$j/bin/java" ]] && { export JAVA_HOME="$j"; break; }
    done
  fi

  if "${runner[@]}" "$kotlinc" -classpath "$cp" -jvm-target 17 -nowarn \
      -d "$WORK/kt-out" "$KOTLIN_SRC"; then
    pass "kotlin: RpcDartWasmPlugin.kt compiles against Flutter + javascriptengine"
  else
    fail "kotlin: RpcDartWasmPlugin.kt does not compile"
  fi
}

note "rpc_dart_wasm: checking native sources"
check_swift
check_kotlin

if [[ "$failed" -ne 0 ]]; then exit 1; fi
if [[ "$ran" -eq 0 ]]; then
  note ""
  note "NOTHING WAS CHECKED. Every native toolchain was missing, so this run"
  note "proves nothing -- do not read it as a pass."
  exit 2
fi
exit 0
