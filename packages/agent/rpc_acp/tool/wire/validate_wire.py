#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT

"""Validate JSON-RPC messages against a pinned ACP stable schema.

Usage: python3 validate_wire.py v1 messages.ndjson
       python3 validate_wire.py v2 messages.ndjson
"""

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
SCHEMA_TAGS = ("schema-v1.29.1", "schema-v2.0.0-alpha.13")
DEFAULT_TAG = {"v1": SCHEMA_TAGS[0], "v2": SCHEMA_TAGS[1]}

METHODS = {
    "v1": {
        "initialize": "InitializeRequest",
        "authenticate": "AuthenticateRequest",
        "logout": "LogoutRequest",
        "session/new": "NewSessionRequest",
        "session/load": "LoadSessionRequest",
        "session/set_mode": "SetSessionModeRequest",
        "session/set_config_option": "SetSessionConfigOptionRequest",
        "session/prompt": "PromptRequest",
        "session/cancel": "CancelNotification",
        "session/list": "ListSessionsRequest",
        "session/delete": "DeleteSessionRequest",
        "session/resume": "ResumeSessionRequest",
        "session/close": "CloseSessionRequest",
        "session/request_permission": "RequestPermissionRequest",
        "session/update": "SessionNotification",
        "fs/write_text_file": "WriteTextFileRequest",
        "fs/read_text_file": "ReadTextFileRequest",
        "terminal/create": "CreateTerminalRequest",
        "terminal/output": "TerminalOutputRequest",
        "terminal/release": "ReleaseTerminalRequest",
        "terminal/wait_for_exit": "WaitForTerminalExitRequest",
        "terminal/kill": "KillTerminalRequest",
        "elicitation/create": "CreateElicitationRequest",
        "elicitation/complete": "CompleteElicitationNotification",
        "$/cancel_request": "CancelRequestNotification",
    },
    "v2": {
        "initialize": "InitializeRequest",
        "auth/login": "LoginAuthRequest",
        "auth/logout": "LogoutAuthRequest",
        "session/new": "NewSessionRequest",
        "session/set_config_option": "SetSessionConfigOptionRequest",
        "session/prompt": "PromptRequest",
        "session/cancel": "CancelSessionNotification",
        "session/list": "ListSessionsRequest",
        "session/delete": "DeleteSessionRequest",
        "session/resume": "ResumeSessionRequest",
        "session/close": "CloseSessionRequest",
        "tool_call/cancel": "CancelToolCallRequest",
        "terminal/cancel": "CancelTerminalRequest",
        "session/request_permission": "RequestPermissionRequest",
        "session/update": "UpdateSessionNotification",
        "elicitation/create": "CreateElicitationRequest",
        "elicitation/complete": "CompleteElicitationNotification",
        "$/cancel_request": "CancelRequestNotification",
    },
}


def main() -> int:
    if (
        len(sys.argv) not in (3, 4)
        or sys.argv[1] not in DEFAULT_TAG
        or (len(sys.argv) == 4 and sys.argv[3] not in SCHEMA_TAGS)
    ):
        print("usage: validate_wire.py {v1|v2} messages.ndjson [schema-tag]", file=sys.stderr)
        return 2
    tag = sys.argv[3] if len(sys.argv) == 4 else DEFAULT_TAG[sys.argv[1]]
    schema_path = ROOT / "docs/protocol" / tag / sys.argv[1] / "schema.json"
    schema = json.loads(schema_path.read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    meta = json.loads(schema_path.with_name("meta.json").read_text())
    official_methods = set().union(
        *(set(meta[group].values()) for group in ("agentMethods", "clientMethods", "protocolMethods"))
    )
    assert set(METHODS[sys.argv[1]]) == official_methods
    assert set(METHODS[sys.argv[1]].values()) <= set(schema["$defs"])
    failures = 0
    pending: dict[tuple[str, object], str] = {}
    duplex = False
    with Path(sys.argv[2]).open() as messages:
        for line_number, line in enumerate(messages, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                print(f"line {line_number}: invalid JSON: {error}", file=sys.stderr)
                failures += 1
                continue
            if isinstance(record, dict) and "from" in record and "message" in record:
                duplex = True
                sender = record["from"]
                if sender not in ("client", "agent"):
                    print(f"line {line_number}: invalid sender", file=sys.stderr)
                    failures += 1
                    continue
                message = record["message"]
                response_sender = "agent" if sender == "client" else "client"
            else:
                message = record
                sender = response_sender = "single"
            errors = list(validator.iter_errors(message))
            if isinstance(message, dict) and "method" in message:
                method = message["method"]
                definition = METHODS[sys.argv[1]].get(method)
                if definition is None:
                    print(f"line {line_number}: unknown method: {method}", file=sys.stderr)
                    failures += 1
                    continue
                if sender != "single" and method not in meta[
                    "agentMethods" if sender == "client" else "clientMethods"
                ].values() and method not in meta["protocolMethods"].values():
                    print(
                        f"line {line_number}: method {method} sent by wrong side",
                        file=sys.stderr,
                    )
                    failures += 1
                    continue
                payload_schema = {"$ref": f"#/$defs/{definition}", "$defs": schema["$defs"]}
                payload_validator = Draft202012Validator(
                    payload_schema, format_checker=FormatChecker()
                )
                errors.extend(payload_validator.iter_errors(message.get("params")))
                if "id" in message:
                    pending[(sender, message["id"])] = method
            elif isinstance(message, dict) and "id" in message:
                method = pending.pop((response_sender, message["id"]), None)
                if method is None:
                    print(f"line {line_number}: response without request", file=sys.stderr)
                    failures += 1
                    continue
                if "result" in message:
                    request_definition = METHODS[sys.argv[1]][method]
                    response_definition = request_definition.removesuffix("Request") + "Response"
                    if not request_definition.endswith("Request") or response_definition not in schema["$defs"]:
                        print(f"line {line_number}: no response schema for {method}", file=sys.stderr)
                        failures += 1
                        continue
                    payload_schema = {
                        "$ref": f"#/$defs/{response_definition}",
                        "$defs": schema["$defs"],
                    }
                    payload_validator = Draft202012Validator(
                        payload_schema, format_checker=FormatChecker()
                    )
                    errors.extend(payload_validator.iter_errors(message["result"]))
            if errors:
                first = errors[0]
                location = "/".join(str(part) for part in first.absolute_path)
                print(
                    f"line {line_number} ({location or '/'}): {first.message}",
                    file=sys.stderr,
                )
                failures += 1
    if duplex and pending:
        print(f"{len(pending)} request(s) without response", file=sys.stderr)
        failures += len(pending)
    if failures:
        print(f"{failures} invalid message(s)", file=sys.stderr)
        return 1
    print(f"ACP {sys.argv[1]} {tag} wire messages valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
