#!/usr/bin/env python3
"""Optional OGX client patches for GLAZOS lab needs.

Applied at OGX pod startup from ConfigMap ``llamastack-mcp-patch``
(see ``openshift/kustomization.yaml`` and ``openshift/ogxserver.yaml``).

External AAP MCP servers are unchanged; these patches only touch the in-pod
``ogx`` package (MCP client + Responses defaults).

1–3 are best-effort streamable-HTTP / connector workarounds (skip if upstream
already fixed the matching source). 4 always injects Glazos default instructions
when Responses omits ``instructions``.
"""
from __future__ import annotations

import site
import sys
from pathlib import Path


PROMPT_PATH = Path("/etc/ogx/patches/glazos-system-prompt.txt")


def site_packages() -> Path:
    for path in site.getsitepackages():
        candidate = Path(path)
        if (candidate / "ogx").is_dir():
            return candidate
    raise SystemExit("ogx site-packages not found")


def patch_file(path: Path, old: str, new: str, label: str, *, required: bool) -> None:
    if not path.is_file():
        msg = f"patch {label}: file not found ({path})"
        if required:
            raise SystemExit(msg)
        print(f"warning: {msg} — skipping", file=sys.stderr)
        return
    text = path.read_text()
    if new in text:
        print(f"patch {label}: already applied")
        return
    if old not in text:
        msg = f"patch {label}: target not found in {path}"
        if required:
            raise SystemExit(msg)
        print(f"warning: {msg} — skipping (likely fixed upstream)", file=sys.stderr)
        return
    path.write_text(text.replace(old, new, 1))
    print(f"patch {label}: applied")


def main() -> None:
    root = site_packages()

    # Best-effort: duplicate MCP initialize breaks streamable-http (external AAP).
    patch_file(
        root / "ogx/providers/utils/tools/mcp.py",
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
        required=False,
    )

    patch_file(
        root / "ogx/core/connectors/connectors.py",
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
        required=False,
    )

    patch_file(
        root / "ogx/providers/inline/responses/builtin/responses/streaming.py",
        """        connector = await connectors_api.get_connector(GetConnectorRequest(connector_id=mcp_tool.connector_id))
""",
        """        connector = await connectors_api.get_connector(
            GetConnectorRequest(connector_id=mcp_tool.connector_id),
            authorization=mcp_tool.authorization,
        )
""",
        "resolve_mcp_connector_id",
        required=False,
    )

    # Required product default: Glazos system prompt when callers omit instructions.
    patch_file(
        root / "ogx/providers/inline/responses/builtin/responses/openai_responses.py",
        """        stream = bool(stream)
        background = bool(background)
        text = OpenAIResponseText(format=OpenAIResponseTextFormat(type="text")) if text is None else text
""",
        f"""        stream = bool(stream)
        background = bool(background)
        if not instructions:
            from pathlib import Path as _Path

            _prompt_path = _Path("{PROMPT_PATH}")
            if _prompt_path.is_file():
                instructions = _prompt_path.read_text().strip() or None
        text = OpenAIResponseText(format=OpenAIResponseTextFormat(type="text")) if text is None else text
""",
        "default_glazos_instructions",
        # Soft: OGX minor releases may reshape openai_responses.py; boot anyway and
        # pass instructions explicitly until the snippet is refreshed.
        required=False,
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        raise
