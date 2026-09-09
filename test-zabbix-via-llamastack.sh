#!/usr/bin/env bash
# Test GLAZOS Llama Stack → Zabbix MCP integration (server-side Responses API).
#
# Python (default):
#   ./test-zabbix-via-llamastack.sh [--check-only]
#
# Pure shell (curl + jq, no Python):
#   ./scripts/test_zabbix_via_llamastack.sh [--check-only]
#
# Single curl only:
#   LLAMA_STACK_BASE_URL=https://llamastack.example.com \\
#   LLAMA_STACK_MODEL=vllm/<model-id> \\
#     ./scripts/test_zabbix_via_llamastack.curl.sh | jq .
#
# Optional env:
#   LLAMA_STACK_BASE_URL      override Route URL
#   OPENSHIFT_NAMESPACE       default: glazos
#   LLAMA_STACK_INSECURE=0    verify TLS
#   LLAMA_STACK_MODEL         default: first vllm/ model from /v1/models
#   ZABBIX_CONNECTOR_ID       default: zabbix
#   ZABBIX_MCP_AUTHORIZATION  optional Bearer token for MCP (if required)
#   MAX_INFER_ITERS           default: 10
set -euo pipefail
cd "$(dirname "$0")"
exec python3 scripts/test_zabbix_via_llamastack.py "$@"
