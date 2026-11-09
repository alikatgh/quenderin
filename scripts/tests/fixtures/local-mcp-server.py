#!/usr/bin/env python3
"""Host fixture for a local tool server. One JSON object per line. No model weights."""

import json
import sys


def reply(message_id, result=None, error=None):
    payload = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        payload["error"] = {"message": error}
    else:
        payload["result"] = result
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    text = line.strip()
    if not text:
        continue
    message = json.loads(text)
    method = message.get("method")
    message_id = message.get("id")
    if method == "initialize":
        reply(message_id, {"protocolVersion": "2026-07-28", "serverInfo": {"name": "fixture"}})
    elif method == "tools/list":
        reply(message_id, {"tools": [{"name": "echo", "title": "Echo"}]})
    elif method == "tools/call":
        params = message.get("params") or {}
        if params.get("name") != "echo":
            reply(message_id, error="no such tool")
            continue
        arguments = params.get("arguments") or {}
        reply(message_id, {"content": arguments.get("input", "")})
    else:
        reply(message_id, error="unknown")
