#!/usr/bin/env bash
# Verify GLAZOS Llama Stack → Ansible Automation Platform MCP via Responses API.
#
# Steps:
#   1. Resolve the Llama Stack Route (or use LLAMA_STACK_BASE_URL).
#   2. GET /v1beta/connectors/<aap-*>/tools — connector reachability (--check-only).
#   3. POST /v1/responses — ask the model to list recent jobs via aap-jobs (full test).
#
# Requires: curl, jq, oc (unless LLAMA_STACK_BASE_URL is set).
set -euo pipefail

DEFAULT_NAMESPACE="${OPENSHIFT_NAMESPACE:-glazos}"
DEFAULT_CONNECTOR_ID="${AAP_CONNECTOR_ID:-aap-jobs}"
MAX_INFER_ITERS="${MAX_INFER_ITERS:-10}"
LLAMA_STACK_INSECURE="${LLAMA_STACK_INSECURE:-1}"
PROMPT=$'Use the Ansible Automation Platform job management MCP tools to list a small sample of recent jobs (at most 5). Return job id, name, and status for each. You must call an AAP tool; do not guess.'

# Connector ids in openshift/config/config.yaml
AAP_CONNECTORS=(
  aap-jobs
  aap-inventory
  aap-monitoring
  aap-users
  aap-security
  aap-platform
)

CHECK_ONLY=0
CHECK_ALL=0
NAMESPACE="$DEFAULT_NAMESPACE"

usage() {
  cat <<'EOF'
Usage: test_aap_via_llamastack.sh [--check-only] [--all-connectors] [--namespace NAME]

Optional env:
  LLAMA_STACK_BASE_URL       override Route URL
  OPENSHIFT_NAMESPACE        default: glazos
  LLAMA_STACK_INSECURE=0     verify TLS (default: skip verify)
  LLAMA_STACK_MODEL          default: first vllm/ model from /v1/models
  AAP_CONNECTOR_ID         default: aap-jobs (full test and single-connector check)
  AAP_MCP_AUTHORIZATION      optional raw MCP token (defaults to AAP_MCP_TOKEN from .env)
  MAX_INFER_ITERS            default: 10
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
    --all-connectors)
      CHECK_ALL=1
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

connector_error_jq='.error.message // .error // empty'

connector_tools_url() {
  local base_url="$1"
  local connector_id="$2"
  local url="${base_url}/v1beta/connectors/${connector_id}/tools"
  if [[ -n "${AAP_MCP_AUTHORIZATION:-}" ]]; then
    url+="?authorization=$(jq -rn --arg v "${AAP_MCP_AUTHORIZATION}" '$v|@uri')"
  fi
  printf '%s' "$url"
}

fetch_connector_tools_quiet() {
  local base_url="$1"
  local connector_id="$2"
  local url
  url="$(connector_tools_url "$base_url" "$connector_id")"
  local payload err count
  payload="$(http_get_json "$url")"
  err="$(jq -r "$connector_error_jq" <<<"$payload")"
  if [[ -n "$err" ]]; then
    echo "error: ${err}" >&2
    return 1
  fi
  count="$(jq -r "$tool_count_jq" <<<"$payload")"
  if [[ "$count" -eq 0 ]]; then
    echo "error: no tools returned" >&2
    return 1
  fi
  printf '%s' "$payload"
}

fetch_connector_tools() {
  local base_url="$1"
  local connector_id="$2"
  local url
  url="$(connector_tools_url "$base_url" "$connector_id")"
  echo "==> GET ${url}" >&2
  local payload err count
  payload="$(http_get_json "$url")"
  err="$(jq -r "$connector_error_jq" <<<"$payload")"
  if [[ -n "$err" ]]; then
    die "connector ${connector_id} error: ${err} (check AAP_MCP_BASE_URL, AAP_MCP_TOKEN in .env, and network path from Llama Stack to AAP)"
  fi
  count="$(jq -r "$tool_count_jq" <<<"$payload")"
  echo "    connector tools: ${count}" >&2
  [[ "$count" -gt 0 ]] || die "connector ${connector_id} returned no AAP MCP tools"
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
        (if .error then
          "    server mcp_call: \(.name // "?") ERROR \(.error)"
        else
          "    server mcp_call: \(.name // "?") ok"
        end)
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

verify_mcp_calls() {
  local response="$1"
  local mcp_calls errors
  mcp_calls="$(jq '[.output[]? | select(.type == "mcp_call")] | length' <<<"$response")"
  [[ "$mcp_calls" -gt 0 ]] || die "Responses API completed without server-side mcp_call items — check AAP connector reachability and Llama Stack logs"

  errors="$(jq -r '[.output[]? | select(.type == "mcp_call" and (.error != null))] | length' <<<"$response")"
  if [[ "$errors" -gt 0 ]]; then
    jq -r '.output[]? | select(.type == "mcp_call" and (.error != null)) | "mcp_call \(.name): \(.error)"' <<<"$response" >&2
    die "AAP MCP tool call failed — see errors above and verify AAP_MCP_TOKEN / upstream AAP MCP URLs"
  fi
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
    --arg auth "${AAP_MCP_AUTHORIZATION:-}" \
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
  verify_mcp_calls "$response"

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

print_sample_tools() {
  local payload="$1"
  echo
  echo "=== sample AAP tool names ==="
  names_file="$(mktemp)"
  jq -r "${tool_names_jq} | sort | .[]" <<<"$payload" >"$names_file"
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
}

check_all_connectors() {
  local base_url="$1"
  local failed=0
  echo "==> checking all AAP connectors" >&2
  for cid in "${AAP_CONNECTORS[@]}"; do
    echo "==> GET $(connector_tools_url "$base_url" "$cid")" >&2
    if payload="$(fetch_connector_tools_quiet "$base_url" "$cid")"; then
      count="$(jq -r "$tool_count_jq" <<<"$payload")"
      echo "    OK ${cid}: ${count} tools" >&2
    else
      echo "    FAIL ${cid}" >&2
      failed=$((failed + 1))
    fi
  done
  if (( failed > 0 )); then
    die "${failed} AAP connector(s) failed — check AAP_MCP_BASE_URL, AAP_MCP_TOKEN in .env, and AAP MCP reachability"
  fi
  echo
  echo "OK: all AAP connectors reachable through Llama Stack."
}

BASE_URL="$(resolve_base_url)"
CONNECTOR_ID="${AAP_CONNECTOR_ID:-$DEFAULT_CONNECTOR_ID}"
echo "==> Llama Stack base URL: ${BASE_URL}" >&2

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if [[ "$CHECK_ALL" -eq 1 ]]; then
    check_all_connectors "$BASE_URL"
    exit 0
  fi
  TOOLS_PAYLOAD="$(fetch_connector_tools "$BASE_URL" "$CONNECTOR_ID")"
  print_sample_tools "$TOOLS_PAYLOAD"
  echo
  echo "OK: AAP tools visible through Llama Stack (connector: ${CONNECTOR_ID})."
  exit 0
fi

TOOLS_PAYLOAD="$(fetch_connector_tools "$BASE_URL" "$CONNECTOR_ID")"
MODEL="$(pick_model "$BASE_URL")"
echo "==> using model: ${MODEL}" >&2
echo "==> using connector: ${CONNECTOR_ID}" >&2
run_responses "$BASE_URL" "$MODEL" "$CONNECTOR_ID"
echo
echo "OK: AAP query via Llama Stack Responses API completed." >&2
