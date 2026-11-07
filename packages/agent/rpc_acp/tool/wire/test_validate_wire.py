#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

"""Regression tests for the pinned ACP wire schema check."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VALIDATOR = Path(__file__).with_name("validate_wire.py")


def validate(
    version: str, *messages: dict, tag: str | None = None
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "messages.ndjson"
        path.write_text("".join(json.dumps(message) + "\n" for message in messages))
        return subprocess.run(
            [sys.executable, str(VALIDATOR), version, str(path), *([tag] if tag else [])],
            capture_output=True,
            text=True,
            check=False,
        )


class WireSchemaTest(unittest.TestCase):
    def test_v1_initialize(self) -> None:
        message = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {}},
        }
        self.assertEqual(validate("v1", message).returncode, 0)
        self.assertEqual(
            validate("v1", message, tag="schema-v2.0.0-alpha.13").returncode, 0
        )

    def test_v2_initialize_requires_info(self) -> None:
        message = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": 2, "capabilities": {}},
        }
        result = validate("v2", message)
        self.assertEqual(result.returncode, 1)
        self.assertIn("'info' is a required property", result.stderr)

    def test_unknown_method_fails(self) -> None:
        message = {"jsonrpc": "2.0", "id": 1, "method": "unknown", "params": {}}
        result = validate("v1", message)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown method", result.stderr)

    def test_v2_initialize_response_requires_info(self) -> None:
        request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": 2,
                "info": {"name": "probe", "version": "1.0.0"},
            },
        }
        response = {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": 2}}
        result = validate("v2", request, response)
        self.assertEqual(result.returncode, 1)
        self.assertIn("'info' is a required property", result.stderr)

    def test_duplex_response_matches_opposite_sender(self) -> None:
        request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {}},
        }
        response = {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {"protocolVersion": 1, "agentCapabilities": {}},
        }
        self.assertEqual(
            validate(
                "v1",
                {"from": "client", "message": request},
                {"from": "agent", "message": response},
            ).returncode,
            0,
        )

    def test_duplex_rejects_unanswered_request(self) -> None:
        request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": 1, "clientCapabilities": {}},
        }
        result = validate("v1", {"from": "client", "message": request})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without response", result.stderr)

    def test_duplex_rejects_method_from_wrong_side(self) -> None:
        message = {
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": {"sessionId": "session-1"},
        }
        result = validate("v1", {"from": "agent", "message": message})
        self.assertEqual(result.returncode, 1)
        self.assertIn("wrong side", result.stderr)


if __name__ == "__main__":
    unittest.main()
