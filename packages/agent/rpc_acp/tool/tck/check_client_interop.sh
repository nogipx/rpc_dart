#!/bin/sh

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

set -eu

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
revision=$(awk -F@ '$1 == "acp-tck " { print $NF }' "$package_dir/tool/tck/requirements-tck.txt")
source_dir="$package_dir/.dart_tool/acp-tck-source-$revision"

if [ ! -d "$source_dir/.git" ]; then
  git init -q "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/agentclientprotocol/acp-tck.git
  git -C "$source_dir" fetch -q --depth 1 origin "$revision"
  git -C "$source_dir" checkout -q --detach FETCH_HEAD
fi
if [ "$(git -C "$source_dir" rev-parse HEAD)" != "$revision" ]; then
  echo "ACP TCK source revision mismatch" >&2
  exit 1
fi

cd "$package_dir"
fvm dart run tool/tck/check_client_interop.dart 1 \
  "$source_dir/tests/fixtures/agents/v1/conforming.py"
fvm dart run tool/tck/check_client_interop.dart 2 \
  "$source_dir/tests/fixtures/agents/v2/conforming.py"
