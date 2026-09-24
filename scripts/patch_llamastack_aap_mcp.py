#!/usr/bin/env python3
"""Patch RHOAI llama_stack 0.7.x for GLAZOS lab needs.

Applied at Llama Stack pod startup from ConfigMap ``llamastack-mcp-patch``
(see ``openshift/kustomization.yaml`` and ``openshift/llamastackdistribution.yaml``).

Fixes:

1. ``get_mcp_server_info()`` calls ``initialize()`` after ``client_wrapper`` already
   initialized the session — AAP rejects the second initialize and Llama Stack falls
   back to SSE (405).
2. ``resolve_mcp_connector_id()`` omits authorization when resolving connector URLs.
3. ``list_connector_tools()`` needlessly calls ``get_connector()`` (server metadata fetch).
4. Responses API has no stack-wide default system prompt — inject Glazos instructions
   from ``glazos-system-prompt.txt`` when the request omits ``instructions``.
"""
from __future__ import annotations

import site
import sys
from pathlib import Path


def site_packages() -> Path:
    for path in site.getsitepackages():
        candidate = Path(path)
        if (candidate / "llama_stack").is_dir():
            return candidate
    raise SystemExit("llama_stack site-packages not found")


def patch_file(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    if new in text:
        print(f"patch {label}: already applied")
        return
    if old not in text:
        raise SystemExit(f"patch {label}: target not found in {path}")
    path.write_text(text.replace(old, new, 1))
    print(f"patch {label}: applied")


def main() -> None:
    root = site_packages()

    patch_file(
        root / "llama_stack/providers/utils/tools/mcp.py",
        """    async with client_wrapper(endpoint, final_headers) as session:
        init_result = await session.initialize()

        return MCPServerInfo(
            name=init_result.serverInfo.name,
            version=init_result.serverInfo.version,
            title=init_result.serverInfo.title,
            description=init_result.instructions,
        )
""",
        """    async with client_wrapper(endpoint, final_headers) as session:
        if session.get_server_capabilities() is not None:
            # client_wrapper already initialized; duplicate initialize breaks streamable-http MCP (AAP).
            return MCPServerInfo(
                name="mcp",
                version="unknown",
                title=None,
                description=None,
            )

        init_result = await session.initialize()

        return MCPServerInfo(
            name=init_result.serverInfo.name,
            version=init_result.serverInfo.version,
            title=init_result.serverInfo.title,
            description=init_result.instructions,
        )
""",
        "get_mcp_server_info",
    )

    patch_file(
        root / "llama_stack/core/connectors/connectors.py",
        """        connector = await self.get_connector(
            GetConnectorRequest(connector_id=request.connector_id), authorization=authorization
        )
        tools = await list_mcp_tools(endpoint=connector.url, authorization=authorization)
""",
        """        connector_json = await self.kvstore.get(self._get_key(request.connector_id))
        if not connector_json:
            raise ConnectorNotFoundError(request.connector_id)
        connector = Connector.model_validate_json(connector_json)
        tools = await list_mcp_tools(endpoint=connector.url, authorization=authorization)
""",
        "list_connector_tools",
    )

    patch_file(
        root
        / "llama_stack/providers/inline/responses/builtin/responses/streaming.py",
        """        connector = await connectors_api.get_connector(GetConnectorRequest(connector_id=mcp_tool.connector_id))
""",
        """        connector = await connectors_api.get_connector(
            GetConnectorRequest(connector_id=mcp_tool.connector_id),
            authorization=mcp_tool.authorization,
        )
""",
        "resolve_mcp_connector_id",
    )

    # Default Glazos system prompt when callers omit Responses API "instructions".
    patch_file(
        root
        / "llama_stack/providers/inline/responses/builtin/responses/openai_responses.py",
        """        stream = bool(stream)
        background = bool(background)
        text = OpenAIResponseText(format=OpenAIResponseTextFormat(type="text")) if text is None else text
""",
        """        stream = bool(stream)
        background = bool(background)
        if not instructions:
            from pathlib import Path as _Path

            _prompt_path = _Path("/etc/llama-stack/patches/glazos-system-prompt.txt")
            if _prompt_path.is_file():
                instructions = _prompt_path.read_text().strip() or None
        text = OpenAIResponseText(format=OpenAIResponseTextFormat(type="text")) if text is None else text
""",
        "default_glazos_instructions",
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        raise
