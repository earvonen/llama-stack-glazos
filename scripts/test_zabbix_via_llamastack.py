#!/usr/bin/env python3
"""Verify GLAZOS Llama Stack can reach Zabbix via the mcp-zabbix tool group.

Steps:
  1. Resolve the Llama Stack Route (or use LLAMA_STACK_BASE_URL).
  2. GET /v1beta/connectors/zabbix/tools — connector reachability.
  3. GET /v1/tools?toolgroup_id=mcp-zabbix — registered tool group.
  4. POST /v1/chat/completions — ask the model to query Zabbix hosts.
  5. Invoke tool_calls via in-cluster Zabbix MCP (oc exec + curl).
  6. POST chat again with tool results and print the answer.
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NAMESPACE = "glazos"
DEFAULT_DEPLOY = "llamastack"
DEFAULT_ZABBIX_MCP = "http://zabbix-mcp:8080/sse"
TOOLGROUP_ID = "mcp-zabbix"
MAX_CHAT_TURNS = int(os.environ.get("MAX_CHAT_TURNS", "6"))


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


def _invoke_zabbix_tool(
    tool_name: str,
    arguments: dict[str, Any],
    *,
    namespace: str,
    deploy: str,
    mcp_url: str,
) -> str:
    helper = Path(__file__).resolve().parent / "_invoke_zabbix_sse_mcp.py"
    cmd = [
        "oc",
        "exec",
        "-i",
        "-n",
        namespace,
        f"deploy/{deploy}",
        "--",
        "python3",
        "-",
        mcp_url,
        tool_name,
        json.dumps(arguments),
    ]
    proc = subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
        input=helper.read_text(encoding="utf-8"),
    )
    if proc.stderr.strip():
        print(proc.stderr.strip(), file=sys.stderr)
    return proc.stdout.strip()


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


def _check_connectors(base_url: str, *, insecure: bool) -> list[dict[str, Any]]:
    url = f"{base_url}/v1beta/connectors/zabbix/tools"
    print(f"==> GET {url}", file=sys.stderr)
    payload = _get_json(url, insecure=insecure)
    tools = _tools_to_openai(payload)
    print(f"    connector tools: {len(tools)}", file=sys.stderr)
    if not tools:
        raise RuntimeError("connector returned no Zabbix tools")
    return tools


def _check_toolgroup(base_url: str, *, insecure: bool) -> list[dict[str, Any]]:
    query = urllib.parse.urlencode({"toolgroup_id": TOOLGROUP_ID})
    url = f"{base_url}/v1/tools?{query}"
    print(f"==> GET {url}", file=sys.stderr)
    try:
        payload = _get_json(url, insecure=insecure)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(
                f"    tool group {TOOLGROUP_ID} not registered (404) — using connector tools",
                file=sys.stderr,
            )
            return []
        raise
    tools = _tools_to_openai(payload)
    print(f"    tool group tools: {len(tools)}", file=sys.stderr)
    if not tools:
        raise RuntimeError(f"tool group {TOOLGROUP_ID} returned no tools")
    return tools


def _run_chat(
    base_url: str,
    tools: list[dict[str, Any]],
    model: str,
    *,
    namespace: str,
    deploy: str,
    mcp_url: str,
    insecure: bool,
) -> None:
    chat_url = f"{base_url}/v1/chat/completions"
    messages: list[dict[str, Any]] = [
        {
            "role": "user",
            "content": (
                "Use the Zabbix tools to list a small sample of monitored hosts "
                "(at most 5). Return host names and their status. "
                "You must call a Zabbix tool; do not guess."
            ),
        }
    ]
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "tools": tools,
        "tool_choice": "auto",
    }

    for turn in range(1, MAX_CHAT_TURNS + 1):
        print(f"==> chat turn {turn}: POST /v1/chat/completions", file=sys.stderr)
        response = _post_json(chat_url, payload, insecure=insecure)
        choice = (response.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        tool_calls = message.get("tool_calls") or []

        if not tool_calls:
            content = message.get("content", "")
            print("\n=== assistant answer ===")
            print(content or json.dumps(response, indent=2))
            return

        messages.append(message)
        for tc in tool_calls:
            fn = tc.get("function") or {}
            tool_name = fn.get("name")
            raw_args = fn.get("arguments") or "{}"
            args = json.loads(raw_args) if isinstance(raw_args, str) else raw_args
            print(f"--- invoking {tool_name}({args}) via Zabbix MCP ---", file=sys.stderr)
            tool_result = _invoke_zabbix_tool(
                tool_name,
                args,
                namespace=namespace,
                deploy=deploy,
                mcp_url=mcp_url,
            )
            print(f"--- tool result ({len(tool_result)} chars) ---", file=sys.stderr)
            print(tool_result[:2000], file=sys.stderr)
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": tc.get("id"),
                    "content": tool_result,
                }
            )

        payload = {
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        }

    raise RuntimeError(f"exceeded MAX_CHAT_TURNS={MAX_CHAT_TURNS} without a final answer")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Test Llama Stack → Zabbix MCP integration for GLAZOS.",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only verify connector and tool group listing (no LLM chat).",
    )
    parser.add_argument(
        "--namespace",
        default=os.environ.get("OPENSHIFT_NAMESPACE", DEFAULT_NAMESPACE),
    )
    args = parser.parse_args()

    namespace = args.namespace
    deploy = os.environ.get("LLAMASTACK_DEPLOY", DEFAULT_DEPLOY)
    mcp_url = os.environ.get("ZABBIX_MCP_URL", DEFAULT_ZABBIX_MCP)
    insecure = os.environ.get("LLAMA_STACK_INSECURE", "1") != "0"

    if not shutil_which("oc"):
        raise RuntimeError("oc not found in PATH (required for Zabbix MCP tool invoke)")

    base_url = _resolve_base_url(namespace)
    print(f"==> Llama Stack base URL: {base_url}", file=sys.stderr)

    connector_tools = _check_connectors(base_url, insecure=insecure)
    toolgroup_tools = _check_toolgroup(base_url, insecure=insecure)
    tools = toolgroup_tools or connector_tools

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
    _run_chat(
        base_url,
        tools,
        model,
        namespace=namespace,
        deploy=deploy,
        mcp_url=mcp_url,
        insecure=insecure,
    )
    print("\nOK: Zabbix query via Llama Stack completed.", file=sys.stderr)
    return 0


def shutil_which(cmd: str) -> str | None:
    for path in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(path) / cmd
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (urllib.error.URLError, subprocess.CalledProcessError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
