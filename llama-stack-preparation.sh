#!/usr/bin/env bash
# Register MCP tool groups after Llama Stack deploy.
# MCP endpoint URLs are read from .env (same as deploy-openshift.sh).
# Run from a machine with cluster access; prefer port-forward for TLS issues:
#   oc port-forward -n glazos svc/llamastack-service 8321:http
#   export LLAMA_STACK_BASE_URL=http://127.0.0.1:8321
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: ${ENV_FILE} not found — copy .env.example to .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

pip install "llama-stack-client>=0.7.0"

MCP_GITHUB_SSE_URL="${MCP_GITHUB_SSE_URL:-http://github-mcp:8080/}"
MCP_OPENSHIFT_SSE_URL="${MCP_OPENSHIFT_SSE_URL:-http://kubernetes-mcp:8080/sse}"
MCP_AAP_PROXY_BASE_URL="${MCP_AAP_PROXY_BASE_URL:-http://aap-mcp-proxy:8080}"
MCP_LINUX_URL="${MCP_LINUX_URL:-http://linux-mcp:8080/mcp}"
MCP_SATELLITE_URL="${MCP_SATELLITE_URL:-http://satellite-mcp:8080/mcp/sse}"
MCP_ZABBIX_URL="${MCP_ZABBIX_URL:-http://zabbix-mcp:8080/mcp}"

AAP_PROXY="${MCP_AAP_PROXY_BASE_URL%/}"
MCP_AAP_JOB_MGMT_URL="${MCP_AAP_JOB_MGMT_URL:-${AAP_PROXY}/job_management/mcp}"
MCP_AAP_INVENTORY_MGMT_URL="${MCP_AAP_INVENTORY_MGMT_URL:-${AAP_PROXY}/inventory_management/mcp}"
MCP_AAP_SYSTEM_MONITOR_URL="${MCP_AAP_SYSTEM_MONITOR_URL:-${AAP_PROXY}/system_monitoring/mcp}"
MCP_AAP_USER_MGMT_URL="${MCP_AAP_USER_MGMT_URL:-${AAP_PROXY}/user_management/mcp}"
MCP_AAP_SECURITY_URL="${MCP_AAP_SECURITY_URL:-${AAP_PROXY}/security_compliance/mcp}"
MCP_AAP_PLATFORM_CONFIG_URL="${MCP_AAP_PLATFORM_CONFIG_URL:-${AAP_PROXY}/platform_configuration/mcp}"

BASE_URL="${LLAMA_STACK_BASE_URL:-http://127.0.0.1:8321}"
ENDPOINT_ARGS=()
if [[ -n "${LLAMA_STACK_BASE_URL:-}" ]]; then
  ENDPOINT_ARGS=(--endpoint "${BASE_URL}")
fi

register() {
  llama-stack-client "${ENDPOINT_ARGS[@]}" toolgroups register "$1" \
    --provider-id model-context-protocol \
    --mcp-endpoint "$2"
}

register mcp-github "${MCP_GITHUB_SSE_URL}"
register mcp-openshift "${MCP_OPENSHIFT_SSE_URL}"
register mcp-aap-jobs "${MCP_AAP_JOB_MGMT_URL}"
register mcp-aap-inventory "${MCP_AAP_INVENTORY_MGMT_URL}"
register mcp-aap-monitoring "${MCP_AAP_SYSTEM_MONITOR_URL}"
register mcp-aap-users "${MCP_AAP_USER_MGMT_URL}"
register mcp-aap-security "${MCP_AAP_SECURITY_URL}"
register mcp-aap-platform "${MCP_AAP_PLATFORM_CONFIG_URL}"
register mcp-linux "${MCP_LINUX_URL}"
register mcp-satellite "${MCP_SATELLITE_URL}"
register mcp-zabbix "${MCP_ZABBIX_URL}"

echo "Registered MCP tool groups. Web search uses builtin::websearch from stack config."
