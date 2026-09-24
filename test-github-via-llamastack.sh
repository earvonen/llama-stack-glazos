#!/usr/bin/env bash
# Test GLAZOS Llama Stack → GitHub MCP integration (server-side Responses API).
#
# Quick check (connector tools only):
#   ./test-github-via-llamastack.sh --check-only
#
# Full test (list open issues via GitHub MCP):
#   GITHUB_TEST_REPO=owner/repo ./test-github-via-llamastack.sh
#
# Optional env:
#   LLAMA_STACK_BASE_URL       override Route URL
#   OPENSHIFT_NAMESPACE        default: glazos
#   LLAMA_STACK_INSECURE=0     verify TLS
#   LLAMA_STACK_MODEL          default: first vllm/ model from /v1/models
#   GITHUB_CONNECTOR_ID        default: github
#   GITHUB_TEST_REPO           owner/repo (required for full test)
#   MAX_INFER_ITERS            default: 10
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/test_github_via_llamastack.sh "$@"
