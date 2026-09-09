#!/usr/bin/env bash
# Single curl: Zabbix hosts via Llama Stack POST /v1/responses (server-side MCP).
#
#   LLAMA_STACK_BASE_URL=https://llamastack.example.com \
#   LLAMA_STACK_MODEL=vllm/<model-id> \
#     ./scripts/test_zabbix_via_llamastack.curl.sh | jq .
#
# Optional: LLAMA_STACK_INSECURE=0 to verify TLS
set -euo pipefail

BASE="${LLAMA_STACK_BASE_URL:?set LLAMA_STACK_BASE_URL}"
MODEL="${LLAMA_STACK_MODEL:?set LLAMA_STACK_MODEL}"
INSECURE="${LLAMA_STACK_INSECURE:-1}"
CURL=(curl -sS -H 'Authorization: Bearer none' -H 'Content-Type: application/json' -H 'Accept: application/json')
[[ "$INSECURE" != "0" ]] && CURL+=(-k)

PAYLOAD="$(jq -nc \
  --arg model "$MODEL" \
  '{
    model: $model,
    input: "Use the Zabbix tools to list a small sample of monitored hosts (at most 5). Return host names and their status. You must call a Zabbix tool; do not guess.",
    max_infer_iters: 10,
    tools: [{
      type: "mcp",
      server_label: "zabbix",
      connector_id: "zabbix",
      require_approval: "never"
    }]
  }')"

exec "${CURL[@]}" -X POST "${BASE%/}/v1/responses" -d "$PAYLOAD"
