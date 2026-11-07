#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

"""Check ACP method coverage against the pinned upstream metadata."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs/protocol"
SOURCES = {
    "agentMethods": [ROOT / "lib/src/acp/wire_caller.dart"],
    "clientMethods": [ROOT / "lib/src/acp/wire_caller.dart", ROOT / "lib/src/acp/client.dart", ROOT / "lib/src/acp/wire.dart"],
    "protocolMethods": [ROOT / "lib/src/acp/json_rpc.dart"],
}


def check(tag: str, version: str) -> list[str]:
    meta = json.loads((DOCS / tag / version / "meta.json").read_text())
    failures = []
    for group, methods in SOURCES.items():
        source = "\n".join(path.read_text() for path in methods)
        for method in meta[group].values():
            # This is an inventory guard, not proof that the handler works.
            if f"'{method}'" not in source and f"r'{method}'" not in source:
                failures.append(f"{tag}/{version}: {group}: {method}")
    return failures


def main() -> int:
    failures = check("schema-v1.29.1", "v1") + check(
        "schema-v2.0.0-alpha.13", "v2"
    )
    if failures:
        print("ACP methods absent from the wire implementation:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print("ACP v1 and v2 method inventory: present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
