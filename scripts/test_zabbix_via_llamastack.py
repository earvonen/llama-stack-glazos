#!/usr/bin/env python3
"""Verify GLAZOS Llama Stack can reach Zabbix via server-side Responses API orchestration.

Steps:
  1. Resolve the Llama Stack Route (or use LLAMA_STACK_BASE_URL).
  2. GET /v1beta/connectors/zabbix/tools — connector reachability (--check-only).
  3. POST /v1/responses — single prompt; Llama Stack executes Zabbix MCP server-side.

Single curl (see scripts/test_zabbix_via_llamastack.curl.sh; set LLAMA_STACK_BASE_URL and LLAMA_STACK_MODEL):
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

DEFAULT_NAMESPACE = "glazos"
DEFAULT_CONNECTOR_ID = "zabbix"
DEFAULT_MAX_INFER_ITERS = int(os.environ.get("MAX_INFER_ITERS", "10"))
PROMPT = (
    "Use the Zabbix tools to list a small sample of monitored hosts "
    "(at most 5). Return host names and their status. "
    "You must call a Zabbix tool; do not guess."
)


def _ssl_context(insecure: bool) -> ssl.SSLContext | None:
    return ssl._create_unverified_context() if insecure else None


def _get_json(url: str, *, insecure: bool = True) -> Any:
    req = urllib.request.Request(
        url,
        headers={"Authorization": "Bearer none", "Accept": "application/json"},
        method="GET",
    )
    with urllib.request.urlopen(req, context=_ssl_context(insecure)) as resp:
        return json.loads(resp.read().decode())


def _post_json(url: str, payload: dict[str, Any], *, insecure: bool = True) -> Any:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": "Bearer none",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, context=_ssl_context(insecure)) as resp:
        return json.loads(resp.read().decode())


def _route_host(namespace: str) -> str:
    proc = subprocess.run(
        [
            "oc",
            "get",
            "route",
            "llamastack",
            "-n",
            namespace,
            "-o",
            "jsonpath={.spec.host}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    host = proc.stdout.strip()
    if not host:
        raise RuntimeError(f"route llamastack has no host in namespace {namespace}")
    return host


def _resolve_base_url(namespace: str) -> str:
    explicit = os.environ.get("LLAMA_STACK_BASE_URL", "").strip()
    if explicit:
        return explicit.rstrip("/")
    return f"https://{_route_host(namespace)}"


def _pick_model(base_url: str, *, insecure: bool) -> str:
    models = _get_json(f"{base_url}/v1/models", insecure=insecure)
    ids = [m.get("id", "") for m in models.get("data", []) if m.get("id")]
    for mid in ids:
        if mid.startswith("vllm/"):
            return mid
    if ids:
        return ids[0]
    raise RuntimeError("no models returned from /v1/models")


def _tools_to_openai(tools_payload: Any) -> list[dict[str, Any]]:
    items = tools_payload.get("data", tools_payload)
    if not isinstance(items, list):
        raise RuntimeError(f"unexpected tools payload: {tools_payload!r}")
    out: list[dict[str, Any]] = []
    for item in items:
        if item.get("type") == "function" and "function" in item:
            out.append(item)
            continue
        name = item.get("name") or item.get("tool_name")
        if not name:
            continue
        out.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": item.get("description", ""),
                    "parameters": item.get("input_schema")
                    or item.get("parameters")
                    or {"type": "object", "properties": {}},
                },
            }
        )
    return out


def _check_connectors(base_url: str, connector_id: str, *, insecure: bool) -> list[dict[str, Any]]:
    url = f"{base_url}/v1beta/connectors/{connector_id}/tools"
    print(f"==> GET {url}", file=sys.stderr)
    payload = _get_json(url, insecure=insecure)
    tools = _tools_to_openai(payload)
    print(f"    connector tools: {len(tools)}", file=sys.stderr)
    if not tools:
        raise RuntimeError("connector returned no Zabbix tools")
    return tools


def _mcp_tool_spec(connector_id: str) -> dict[str, Any]:
    tool: dict[str, Any] = {
        "type": "mcp",
        "server_label": connector_id,
        "connector_id": connector_id,
        "require_approval": "never",
    }
    auth = os.environ.get("ZABBIX_MCP_AUTHORIZATION", "").strip()
    if auth:
        tool["authorization"] = auth
    return tool


def _extract_output_text(response: dict[str, Any]) -> str:
    if response.get("output_text"):
        return str(response["output_text"]).strip()

    parts: list[str] = []
    for item in response.get("output") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "message":
            for block in item.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "output_text":
                    text = block.get("text", "")
                    if text:
                        parts.append(str(text))
    return "\n".join(parts).strip()


def _log_mcp_activity(response: dict[str, Any]) -> None:
    for item in response.get("output") or []:
        if not isinstance(item, dict):
            continue
        item_type = item.get("type", "")
        if item_type == "mcp_list_tools":
            tools = item.get("tools") or []
            print(f"    server mcp_list_tools: {len(tools)} tools", file=sys.stderr)
        elif item_type == "mcp_call":
            name = item.get("name", "?")
            status = item.get("status", "?")
            print(f"    server mcp_call: {name} status={status}", file=sys.stderr)


def _run_responses(
    base_url: str,
    model: str,
    connector_id: str,
    *,
    insecure: bool,
) -> None:
    url = f"{base_url}/v1/responses"
    payload: dict[str, Any] = {
        "model": model,
        "input": PROMPT,
        "tools": [_mcp_tool_spec(connector_id)],
        "max_infer_iters": DEFAULT_MAX_INFER_ITERS,
    }
    print(f"==> POST {url}", file=sys.stderr)
    response = _post_json(url, payload, insecure=insecure)
    _log_mcp_activity(response)

    output = response.get("output") or []
    mcp_calls = [i for i in output if isinstance(i, dict) and i.get("type") == "mcp_call"]
    if not mcp_calls:
        raise RuntimeError(
            "Responses API completed without server-side mcp_call items — "
            "check connector reachability and Llama Stack logs"
        )

    answer = _extract_output_text(response)
    print("\n=== assistant answer ===")
    print(answer or json.dumps(response, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Test Llama Stack → Zabbix MCP via server-side Responses API.",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only verify connector tool listing (no LLM request).",
    )
    parser.add_argument(
        "--namespace",
        default=os.environ.get("OPENSHIFT_NAMESPACE", DEFAULT_NAMESPACE),
    )
    args = parser.parse_args()

    connector_id = os.environ.get("ZABBIX_CONNECTOR_ID", DEFAULT_CONNECTOR_ID)
    insecure = os.environ.get("LLAMA_STACK_INSECURE", "1") != "0"

    base_url = _resolve_base_url(args.namespace)
    print(f"==> Llama Stack base URL: {base_url}", file=sys.stderr)

    tools = _check_connectors(base_url, connector_id, insecure=insecure)

    if args.check_only:
        print("\n=== sample Zabbix tool names ===")
        names = sorted(t["function"]["name"] for t in tools)
        for name in names[:15]:
            print(name)
        if len(names) > 15:
            print(f"... and {len(names) - 15} more")
        print("\nOK: Zabbix tools visible through Llama Stack.")
        return 0

    model = os.environ.get("LLAMA_STACK_MODEL") or _pick_model(base_url, insecure=insecure)
    print(f"==> using model: {model}", file=sys.stderr)
    print(f"==> using connector: {connector_id}", file=sys.stderr)
    _run_responses(base_url, model, connector_id, insecure=insecure)
    print("\nOK: Zabbix query via Llama Stack Responses API completed.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (urllib.error.URLError, subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
