#!/usr/bin/env bash
# Test GLAZOS Llama Stack → Linux MCP integration (server-side Responses API).
#
# Quick check (no LLM, no SSH):
#   ./test-linux-via-llamastack.sh --check-only
#
# Full test (SSH via linux-mcp pod):
#   LINUX_MCP_TEST_HOST=rhel-host.example.com ./test-linux-via-llamastack.sh
#
# Optional env:
#   LLAMA_STACK_BASE_URL       override Route URL
#   OPENSHIFT_NAMESPACE        default: glazos
#   LLAMA_STACK_INSECURE=0     verify TLS
#   LLAMA_STACK_MODEL          default: first vllm/ model from /v1/models
#   LINUX_CONNECTOR_ID         default: linux
#   LINUX_MCP_TEST_HOST        SSH target (required for full test)
#   LINUX_MCP_AUTHORIZATION    optional Bearer token for MCP HTTP auth
#   MAX_INFER_ITERS            default: 10
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/test_linux_via_llamastack.sh "$@"
