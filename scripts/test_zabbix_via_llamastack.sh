#!/usr/bin/env bash
# Verify GLAZOS Llama Stack → Zabbix via server-side Responses API orchestration.
#
# Steps:
#   1. Resolve the Llama Stack Route (or use LLAMA_STACK_BASE_URL).
#   2. GET /v1beta/connectors/zabbix/tools — connector reachability (--check-only).
#   3. POST /v1/responses — single prompt; Llama Stack executes Zabbix MCP server-side.
#
# Requires: curl, jq, oc (unless LLAMA_STACK_BASE_URL is set).
set -euo pipefail

DEFAULT_NAMESPACE="${OPENSHIFT_NAMESPACE:-glazos}"
DEFAULT_CONNECTOR_ID="${ZABBIX_CONNECTOR_ID:-zabbix}"
MAX_INFER_ITERS="${MAX_INFER_ITERS:-10}"
LLAMA_STACK_INSECURE="${LLAMA_STACK_INSECURE:-1}"
PROMPT=$'Use the Zabbix tools to list a small sample of monitored hosts (at most 5). Return host names and their status. You must call a Zabbix tool; do not guess.'

CHECK_ONLY=0
NAMESPACE="$DEFAULT_NAMESPACE"

usage() {
  cat <<'EOF'
Usage: test_zabbix_via_llamastack.sh [--check-only] [--namespace NAME]

Optional env:
  LLAMA_STACK_BASE_URL      override Route URL
  OPENSHIFT_NAMESPACE       default: glazos
  LLAMA_STACK_INSECURE=0    verify TLS (default: skip verify)
  LLAMA_STACK_MODEL         default: first vllm/ model from /v1/models
  ZABBIX_CONNECTOR_ID       default: zabbix
  ZABBIX_MCP_AUTHORIZATION  optional Bearer token for MCP (if required)
  MAX_INFER_ITERS           default: 10
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
      shift
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

require_cmd curl
require_cmd jq

curl_args=( -sS -H "Authorization: Bearer none" -H "Accept: application/json" )
if [[ "$LLAMA_STACK_INSECURE" != "0" ]]; then
  curl_args+=( -k )
fi

resolve_base_url() {
  if [[ -n "${LLAMA_STACK_BASE_URL:-}" ]]; then
    printf '%s' "${LLAMA_STACK_BASE_URL%/}"
    return
  fi
  require_cmd oc
  local host
  host="$(oc get route llamastack -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
  [[ -n "$host" ]] || die "route llamastack has no host in namespace ${NAMESPACE}"
  printf 'https://%s' "$host"
}

http_get_json() {
  local url="$1"
  curl "${curl_args[@]}" "$url"
}

http_post_json() {
  local url="$1"
  local body="$2"
  curl "${curl_args[@]}" \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary "$body" \
    "$url"
}

tool_names_jq='
  (.data // .)
  | if type == "array" then . else [] end
  | map(.name // .tool_name // empty)
  | map(select(. != ""))
'

tool_count_jq="${tool_names_jq} | length"

check_connectors() {
  local base_url="$1"
  local connector_id="$2"
  local url="${base_url}/v1beta/connectors/${connector_id}/tools"
  echo "==> GET ${url}" >&2
  local payload
  payload="$(http_get_json "$url")"
  local count
  count="$(jq -r "$tool_count_jq" <<<"$payload")"
  echo "    connector tools: ${count}" >&2
  [[ "$count" -gt 0 ]] || die "connector returned no Zabbix tools"
  printf '%s' "$payload"
}

pick_model() {
  local base_url="$1"
  if [[ -n "${LLAMA_STACK_MODEL:-}" ]]; then
    printf '%s' "$LLAMA_STACK_MODEL"
    return
  fi
  local models
  models="$(http_get_json "${base_url}/v1/models")"
  local model
  model="$(jq -r '
    [.data[]?.id // empty]
    | (map(select(startswith("vllm/"))) + .)[0] // empty
  ' <<<"$models")"
  [[ -n "$model" ]] || die "no models returned from /v1/models"
  printf '%s' "$model"
}

log_mcp_activity() {
  local response="$1"
  jq -r '
    .output[]?
    | if .type == "mcp_list_tools" then
        "    server mcp_list_tools: \(.tools | length) tools"
      elif .type == "mcp_call" then
        "    server mcp_call: \(.name // "?") status=\(.status // "?")"
      else empty end
  ' <<<"$response" >&2
}

extract_output_text() {
  local response="$1"
  jq -r '
    if (.output_text // "") != "" then .output_text
    else
      [
        .output[]?
        | select(.type == "message")
        | .content[]?
        | select(.type == "output_text")
        | .text // empty
      ]
      | join("\n")
    end
  ' <<<"$response"
}

run_responses() {
  local base_url="$1"
  local model="$2"
  local connector_id="$3"
  local url="${base_url}/v1/responses"
  local payload
  payload="$(jq -n \
    --arg model "$model" \
    --arg input "$PROMPT" \
    --arg cid "$connector_id" \
    --arg auth "${ZABBIX_MCP_AUTHORIZATION:-}" \
    --argjson max_infer_iters "$MAX_INFER_ITERS" \
    '{
      model: $model,
      input: $input,
      max_infer_iters: $max_infer_iters,
      tools: [{
        type: "mcp",
        server_label: $cid,
        connector_id: $cid,
        require_approval: "never"
      } + (if ($auth | length) > 0 then {authorization: $auth} else {} end)]
    }')"

  echo "==> POST ${url}" >&2
  local response
  response="$(http_post_json "$url" "$payload")"
  log_mcp_activity "$response"

  local mcp_calls
  mcp_calls="$(jq '[.output[]? | select(.type == "mcp_call")] | length' <<<"$response")"
  if [[ "$mcp_calls" -eq 0 ]]; then
    die "Responses API completed without server-side mcp_call items — check connector reachability and Llama Stack logs"
  fi

  local answer
  answer="$(extract_output_text "$response")"
  echo
  echo "=== assistant answer ==="
  if [[ -n "$answer" ]]; then
    printf '%s\n' "$answer"
  else
    jq . <<<"$response"
  fi
}

BASE_URL="$(resolve_base_url)"
CONNECTOR_ID="${ZABBIX_CONNECTOR_ID:-$DEFAULT_CONNECTOR_ID}"
echo "==> Llama Stack base URL: ${BASE_URL}" >&2

TOOLS_PAYLOAD="$(check_connectors "$BASE_URL" "$CONNECTOR_ID")"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo
  echo "=== sample Zabbix tool names ==="
  names_file="$(mktemp)"
  jq -r "${tool_names_jq} | sort | .[]" <<<"$TOOLS_PAYLOAD" >"$names_file"
  total=0
  while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -z "$name" ]] && continue
    total=$((total + 1))
    if (( total <= 15 )); then
      echo "$name"
    fi
  done <"$names_file"
  rm -f "$names_file"
  if (( total > 15 )); then
    echo "... and $((total - 15)) more"
  fi
  echo
  echo "OK: Zabbix tools visible through Llama Stack."
  exit 0
fi

MODEL="$(pick_model "$BASE_URL")"
echo "==> using model: ${MODEL}" >&2
echo "==> using connector: ${CONNECTOR_ID}" >&2
run_responses "$BASE_URL" "$MODEL" "$CONNECTOR_ID"
echo
echo "OK: Zabbix query via Llama Stack Responses API completed." >&2
