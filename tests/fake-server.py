#!/usr/bin/env python3
"""Stand-in for nextedit-server: answers every request after a short delay
with a fixed prediction, so tests can edit the buffer mid-flight. With
--multiline the replacement spans two lines, for the multiline-filter test."""

import json
import sys
import time

replacement = ["def sub(a: int, b: int) -> int:"]
if "--multiline" in sys.argv:
    replacement = ["def sub(a: int, b: int) -> int:", "    return int(a - b)"]

for line in sys.stdin:
    req = json.loads(line)
    time.sleep(0.4)
    print(json.dumps({
        "id": req["id"],
        "result": {
            "has_edit": True,
            "start_line": 4,
            "end_line": 4,
            "replacement": replacement,
        },
    }), flush=True)
