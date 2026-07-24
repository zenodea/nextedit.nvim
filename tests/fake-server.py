#!/usr/bin/env python3
"""Stand-in for nextedit-server: answers every request after a short delay
with a fixed prediction, so tests can edit the buffer mid-flight."""

import json
import sys
import time

for line in sys.stdin:
    req = json.loads(line)
    time.sleep(0.4)
    print(json.dumps({
        "id": req["id"],
        "result": {
            "has_edit": True,
            "start_line": 4,
            "end_line": 4,
            "replacement": ["def sub(a: int, b: int) -> int:"],
        },
    }), flush=True)
