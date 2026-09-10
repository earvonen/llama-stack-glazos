#!/usr/bin/env bash
# Test GLAZOS Llama Stack → Ansible Automation Platform MCP (server-side Responses API).
#
# Quick check — single connector (default aap-jobs):
#   ./test-aap-via-llamastack.sh --check-only
#
# Quick check — all six AAP connectors:
#   ./test-aap-via-llamastack.sh --check-only --all-connectors
#
# Full test (list recent jobs via aap-jobs):
#   ./test-aap-via-llamastack.sh
#
# Optional env:
#   LLAMA_STACK_BASE_URL       override Route URL
#   OPENSHIFT_NAMESPACE        default: glazos
#   LLAMA_STACK_INSECURE=0     verify TLS
#   LLAMA_STACK_MODEL          default: first vllm/ model from /v1/models
#   AAP_CONNECTOR_ID           default: aap-jobs
#   AAP_MCP_AUTHORIZATION      optional raw MCP token (defaults to AAP_MCP_TOKEN from .env)
#   MAX_INFER_ITERS            default: 10
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
# Llama Stack expects the raw token in authorization (Bearer prefix added server-side).
export AAP_MCP_AUTHORIZATION="${AAP_MCP_AUTHORIZATION:-${AAP_MCP_TOKEN:-}}"
exec bash scripts/test_aap_via_llamastack.sh "$@"
