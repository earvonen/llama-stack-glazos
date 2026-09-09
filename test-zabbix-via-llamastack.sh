#!/usr/bin/env bash
# Test GLAZOS Llama Stack → Zabbix MCP integration (server-side Responses API).
#
# Quick check (no LLM):
#   ./test-zabbix-via-llamastack.sh --check-only
#
# Full test (single POST /v1/responses; Llama Stack orchestrates MCP):
#   ./test-zabbix-via-llamastack.sh
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
