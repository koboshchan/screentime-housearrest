#!/usr/bin/env python3
"""Audit publishable sources without printing secret values or reading private archives."""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
PRIVATE = "poc/private/"
PATTERNS = {
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "github token": re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    "credential literal": re.compile(r"""(?ix)\b(?:password|passwd|sudo_pass|sshpass|api_key|access_token)\b\s*[:=]\s*["'][^"'\n]{3,}["']"""),
    "sudo password pipe": re.compile(r"(?i)echo\s+.+\|\s*(?:sudo|.*sudo\s+-S)"),
}
EXCLUDED = {".git", ".build", "build", "DerivedData", "__pycache__", ".theos", "packages"}
def main():
    problems = []
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    problems += [{"path": p, "reason": "private content tracked"} for p in tracked if p.startswith(PRIVATE)]
    if (ROOT / "poc").exists():
        problems.append({"path": "poc", "reason": "removed research folder must not return"})
    count = 0
    for folder in ("macOS", "iOS"):
        for p in (ROOT / folder).rglob("*"):
            rel = p.relative_to(ROOT).as_posix()
            if rel.startswith(PRIVATE) or any(part in EXCLUDED for part in p.parts):
                continue
            if p.is_symlink():
                if not rel.startswith(PRIVATE):
                    problems.append({"path": rel, "reason": "review symlink before publication"})
                continue
            if rel.startswith(PRIVATE) or not p.is_file() or any(part in EXCLUDED for part in p.parts):
                continue
            try:
                text = p.read_text()
            except UnicodeError:
                problems.append({"path": rel, "reason": "binary in publishable source tree"})
                continue
            count += 1
            if p.name == "audit.py":
                continue
            for line, content in enumerate(text.splitlines(), 1):
                for reason, pattern in PATTERNS.items():
                    if pattern.search(content):
                        problems.append({"path": rel, "line": line, "reason": reason})
    print(json.dumps({"filesChecked": count, "findings": problems, "privateArchiveExcluded": True}, indent=2))
    return bool(problems)
if __name__ == "__main__":
    sys.exit(main())
