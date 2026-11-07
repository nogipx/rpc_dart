#!/bin/sh

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

set -eu
export PYTHONDONTWRITEBYTECODE=1

package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
venv_dir="$package_dir/.dart_tool/acp-schema-venv"

if [ ! -x "$venv_dir/bin/python" ]; then
  python3 -m venv "$venv_dir"
fi
if ! "$venv_dir/bin/python" -c 'import jsonschema' 2>/dev/null; then
  "$venv_dir/bin/pip3" install -r "$package_dir/tool/wire/requirements.txt"
fi

report_dir="$package_dir/.dart_tool/acp-schema-reports"
mkdir -p "$report_dir"
v1_file="$report_dir/client-v1.ndjson"
v2_file="$report_dir/client-v2.ndjson"

cd "$package_dir"
fvm dart run tool/wire/emit_initialize_wire.dart v1 > "$v1_file"
fvm dart run tool/wire/emit_initialize_wire.dart v2 > "$v2_file"
"$venv_dir/bin/python" tool/wire/check_probe_coverage.py v1 "$v1_file"
"$venv_dir/bin/python" tool/wire/check_probe_coverage.py v2 "$v2_file"
for tag in schema-v1.29.1 schema-v2.0.0-alpha.13; do
  "$venv_dir/bin/python" tool/wire/validate_wire.py v1 "$v1_file" "$tag"
  "$venv_dir/bin/python" tool/wire/validate_wire.py v2 "$v2_file" "$tag"
done
"$venv_dir/bin/python" -m unittest tool/wire/test_validate_wire.py 2>&1
"$venv_dir/bin/python" tool/wire/write_schema_report.py "$report_dir"
