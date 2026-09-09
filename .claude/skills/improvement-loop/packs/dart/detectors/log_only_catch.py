#!/usr/bin/env python3
"""Detector for U-06 in Dart: catch blocks whose only action is a log call.

Prints path:line: the catch header. Heuristic: the braced body consists only of
calls containing log/print/warning/severe/fine/info/debug. Run from the
repository root; the arguments are directories (lib by default).
"""
import os
import re
import sys

CATCH = re.compile(r"\bcatch\s*\(([^)]*)\)\s*\{")
LOG = re.compile(r"\b(log|logger|_log|print|debugPrint|warning|severe|fine|info|debug|error)\b", re.I)
SKIP_DIRS = {".git", "build", ".dart_tool", ".claude"}

def body_after(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return text[start + 1:]

def main(roots):
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            for fn in files:
                if not fn.endswith(".dart"):
                    continue
                path = os.path.join(d, fn)
                try:
                    text = open(path, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                for m in CATCH.finditer(text):
                    body = body_after(text, m.end() - 1)
                    stmts = [s.strip() for s in body.split(";") if s.strip()]
                    if stmts and all(LOG.search(s) and "rethrow" not in s and "throw" not in s for s in stmts):
                        line = text.count("\n", 0, m.start()) + 1
                        print(f"{path}:{line}: catch ({m.group(1).strip()}) — log only")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["lib"]))
