#!/usr/bin/env python3
"""Measure end-to-end prediction latency of nextedit-server.

Spawns the release binary, sends it the same JSON-lines requests the plugin
would, and times each round trip. Provider/model/key come from the usual
environment variables (NEXTEDIT_PROVIDER, NEXTEDIT_MODEL, NEXTEDIT_API_KEY,
provider key fallbacks), or from --provider/--model.

Examples:
  python3 scripts/bench.py --provider mercury --model mercury-2
  python3 scripts/bench.py --provider copilot -n 10
  python3 scripts/bench.py --provider ollama --file lua/nextedit/init.lua
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "server" / "target" / "release" / "nextedit-server"

SAMPLE_LINES = '''\
def add(a: int, b: int) -> int:
    return a + b

def sub(a, b):
    return a - b

def mul(a, b):
    return a * b

def div(a, b):
    return a / b
'''.splitlines()

SAMPLE_EDIT = """\
@@ -1,2 +1,2 @@
-def add(a, b):
+def add(a: int, b: int) -> int:
     return a + b"""


def build_params(args):
    if args.file:
        lines = Path(args.file).read_text().splitlines()
        cursor = max(1, len(lines) // 2)
        lo = max(0, cursor - 1 - args.context)
        hi = min(len(lines), cursor + args.context)
        return {
            "path": args.file,
            "filetype": Path(args.file).suffix.lstrip(".") or "text",
            "cursor_line": cursor,
            "excerpt_start": lo + 1,
            "excerpt_lines": lines[lo:hi],
            "recent_edits": [],
        }
    return {
        "path": "sample.py",
        "filetype": "python",
        "cursor_line": 2,
        "excerpt_start": 1,
        "excerpt_lines": SAMPLE_LINES,
        "recent_edits": [SAMPLE_EDIT],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-n", "--runs", type=int, default=5)
    ap.add_argument("--provider", help="sets NEXTEDIT_PROVIDER")
    ap.add_argument("--model", help="sets NEXTEDIT_MODEL")
    ap.add_argument("--file", help="benchmark against a real file instead of the built-in sample")
    ap.add_argument("--context", type=int, default=40, help="lines of context around the cursor with --file")
    args = ap.parse_args()

    if not BINARY.exists():
        sys.exit(f"{BINARY} not found — run: cd server && cargo build --release")

    env = os.environ.copy()
    if args.provider:
        env["NEXTEDIT_PROVIDER"] = args.provider
    if args.model:
        env["NEXTEDIT_MODEL"] = args.model

    params = build_params(args)
    proc = subprocess.Popen(
        [str(BINARY)], env=env, text=True, bufsize=1,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )

    provider = env.get("NEXTEDIT_PROVIDER", "anthropic")
    model = env.get("NEXTEDIT_MODEL", "(default)")
    print(f"provider={provider} model={model} runs={args.runs} "
          f"excerpt={len(params['excerpt_lines'])} lines")

    times = []
    for i in range(args.runs):
        req = json.dumps({"id": i + 1, "params": params})
        t0 = time.monotonic()
        proc.stdin.write(req + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        elapsed = time.monotonic() - t0
        if not line:
            err = proc.stderr.read()
            sys.exit(f"server exited (code {proc.poll()}): {err.strip()}")
        resp = json.loads(line)
        if resp.get("error"):
            print(f"  run {i + 1}: {elapsed * 1000:7.0f} ms  ERROR: {resp['error']}")
            continue
        r = resp["result"]
        what = (f"edit lines {r['start_line']}-{r['end_line']} "
                f"({len(r['replacement'])} replacement lines)") if r["has_edit"] else "no edit"
        print(f"  run {i + 1}: {elapsed * 1000:7.0f} ms  {what}")
        times.append(elapsed)

    proc.stdin.close()
    proc.wait(timeout=30)

    if times:
        ms = [t * 1000 for t in times]
        print(f"\nmin {min(ms):.0f} ms | median {statistics.median(ms):.0f} ms | "
              f"mean {statistics.mean(ms):.0f} ms | max {max(ms):.0f} ms")
        if len(ms) > 1:
            print(f"first (cold) {ms[0]:.0f} ms | rest mean {statistics.mean(ms[1:]):.0f} ms")
        print("note: perceived latency in nvim = this + debounce_ms (default 300)")


if __name__ == "__main__":
    main()
