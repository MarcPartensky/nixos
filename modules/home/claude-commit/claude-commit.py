#!/usr/bin/env python3
import subprocess
import sys
import json
import urllib.request
import urllib.error
import os

MODEL = "claude-haiku-4-5-20251001"
MAX_TOKENS = 200
SECRET_PATH = os.path.expanduser("~/.config/sops-nix/secrets/anthropic_api_key")

def get_api_key() -> str:
    try:
        with open(SECRET_PATH) as f:
            key = f.read().strip()
        if not key:
            raise ValueError("empty")
        return key
    except Exception as e:
        print(f"claude-commit: cannot read API key from {SECRET_PATH}: {e}", file=sys.stderr)
        sys.exit(1)

def get_staged_diff() -> str:
    result = subprocess.run(
        ["git", "diff", "--cached"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"claude-commit: git error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()

def generate_commit_message(diff: str, api_key: str) -> str:
    prompt = (
        "Generate a concise conventional commit message (type: short description) for this diff.\n"
        "Rules:\n"
        "- Use one of: feat, fix, docs, style, refactor, test, chore\n"
        "- Max 72 chars\n"
        "- Lowercase\n"
        "- No period at end\n"
        "- Reply with ONLY the commit message, nothing else\n\n"
        f"Diff:\n{diff}"
    )
    payload = json.dumps({
        "model": MODEL,
        "max_tokens": MAX_TOKENS,
        "messages": [{"role": "user", "content": prompt}]
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
            return data["content"][0]["text"].strip()
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"claude-commit: API error {e.code}: {body}", file=sys.stderr)
        sys.exit(1)

def main():
    api_key = get_api_key()
    diff = get_staged_diff()

    if not diff:
        print("claude-commit: nothing staged", file=sys.stderr)
        sys.exit(1)

    msg = generate_commit_message(diff, api_key)

    if not msg:
        print("claude-commit: empty response from API", file=sys.stderr)
        sys.exit(1)

    print(f"=> {msg}")

    if os.environ.get("CC_DRY") == "1":
        print("(dry-run, not committing)")
        return

    result = subprocess.run(["git", "commit", "-m", msg])
    sys.exit(result.returncode)

if __name__ == "__main__":
    main()
