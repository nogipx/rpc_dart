#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

"""Fail if the real-message probe silently skips a covered method."""

import json
import sys
from pathlib import Path


COMMON = {
    "initialize",
    "session/new",
    "session/list",
    "session/delete",
    "session/close",
    "session/set_config_option",
    "session/resume",
    "session/cancel",
    "session/prompt",
}
EXPECTED = {
    "v1": COMMON | {"authenticate", "logout", "session/load", "session/set_mode"},
    "v2": COMMON | {"auth/login", "auth/logout", "tool_call/cancel", "terminal/cancel"},
}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in EXPECTED:
        print("usage: check_probe_coverage.py {v1|v2} client.ndjson", file=sys.stderr)
        return 2
    methods = {
        message["method"]
        for line in Path(sys.argv[2]).read_text().splitlines()
        if (message := json.loads(line)).get("method")
    }
    missing = EXPECTED[sys.argv[1]] - methods
    if missing:
        print("missing probed methods: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 1
    print(f"ACP {sys.argv[1]} client probe: {len(methods)} methods captured")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
