#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

"""Record hashes and coverage for a passing ACP wire validation run."""

import hashlib
import json
import sys
from pathlib import Path

from validate_wire import ROOT, SCHEMA_TAGS


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: write_schema_report.py report-directory", file=sys.stderr)
        return 2
    report_dir = Path(sys.argv[1])
    schemas = [
        {
            "tag": tag,
            "version": version,
            "schema_sha256": sha256(ROOT / "docs/protocol" / tag / version / "schema.json"),
            "meta_sha256": sha256(ROOT / "docs/protocol" / tag / version / "meta.json"),
        }
        for tag in SCHEMA_TAGS
        for version in ("v1", "v2")
    ]
    transcripts = []
    for name in ("client-v1.ndjson", "client-v2.ndjson"):
        path = report_dir / name
        messages = []
        for line in path.read_text().splitlines():
            record = json.loads(line)
            messages.append(record.get("message", record))
        transcripts.append(
            {
                "file": path.name,
                "sha256": sha256(path),
                "messages": len(messages),
                "methods": sorted({m["method"] for m in messages if "method" in m}),
                "responses": sum("result" in m or "error" in m for m in messages),
            }
        )
    (report_dir / "report.json").write_text(
        json.dumps(
            {"validation": "passed", "schemas": schemas, "transcripts": transcripts},
            indent=2,
        )
        + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
