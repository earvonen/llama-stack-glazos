#!/usr/bin/env python3
"""Invoke a Zabbix MCP tool over SSE transport (used via oc exec from test script)."""
from __future__ import annotations

import json
import queue
import sys
import threading
import time
import urllib.request


def main() -> int:
    mcp_base = sys.argv[1].rstrip("/")
    if mcp_base.endswith("/sse"):
        mcp_base = mcp_base[:-4]
    tool_name = sys.argv[2]
    arguments = json.loads(sys.argv[3])

    responses: queue.Queue[dict] = queue.Queue()
    endpoint_holder: list[str] = []
    errors: list[str] = []

    def sse_reader() -> None:
        try:
            req = urllib.request.Request(
                f"{mcp_base}/sse",
                headers={"Accept": "text/event-stream"},
            )
            with urllib.request.urlopen(req, timeout=120) as resp:
                event = None
                while True:
                    line = resp.readline().decode().rstrip("\r\n")
                    if not line:
                        continue
                    if line.startswith("event: "):
                        event = line[7:]
                    elif line.startswith("data: "):
                        data = line[6:]
                        if event == "endpoint":
                            endpoint_holder.append(data)
                        elif event == "message":
                            responses.put(json.loads(data))
                        event = None
        except Exception as exc:  # noqa: BLE001
            errors.append(str(exc))

    threading.Thread(target=sse_reader, daemon=True).start()
    for _ in range(100):
        if endpoint_holder or errors:
            break
        time.sleep(0.05)
    if errors:
        raise RuntimeError(errors[0])
    if not endpoint_holder:
        raise RuntimeError("no SSE endpoint event from Zabbix MCP")

    messages_url = mcp_base + endpoint_holder[0]

    def post(payload: dict) -> None:
        data = json.dumps(payload).encode()
        req = urllib.request.Request(
            messages_url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=120).read()

    post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test-zabbix-via-llamastack", "version": "0"},
            },
        }
    )
    post({"jsonrpc": "2.0", "method": "notifications/initialized"})
    post(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        }
    )

    for _ in range(60):
        try:
            msg = responses.get(timeout=2)
        except queue.Empty:
            continue
        if msg.get("id") != 2:
            continue
        if "error" in msg:
            raise RuntimeError(json.dumps(msg["error"]))
        result = msg.get("result", {})
        content = result.get("content", [])
        if not content:
            print(json.dumps(result))
            return 0
        texts = [c.get("text", "") for c in content if c.get("type") == "text"]
        print("\n".join(texts) if texts else json.dumps(content))
        return 0

    raise RuntimeError("timeout waiting for tools/call response")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
