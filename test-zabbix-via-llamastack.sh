#!/usr/bin/env bash
# Test GLAZOS Llama Stack → Zabbix MCP integration.
#
# Quick check (no LLM):
#   ./test-zabbix-via-llamastack.sh --check-only
#
# Full test (chat + Zabbix tool call):
#   ./test-zabbix-via-llamastack.sh
#
# Optional env:
#   LLAMA_STACK_BASE_URL   override Route URL
#   OPENSHIFT_NAMESPACE    default: glazos
#   LLAMA_STACK_INSECURE=0 verify TLS
#   ZABBIX_MCP_URL         default: http://zabbix-mcp:8080/sse
set -euo pipefail
cd "$(dirname "$0")"
exec python3 scripts/test_zabbix_via_llamastack.py "$@"
