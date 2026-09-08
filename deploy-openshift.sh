#!/usr/bin/env bash
# Deploy GLAZOS OpenShift overlay. Secrets, URLs, and ConfigMaps are applied from .env
# (see .env.example). Default namespace: glazos.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAMESPACE="${OPENSHIFT_NAMESPACE:-glazos}"
KUSTOMIZE_DIR="${KUSTOMIZE_DIR:-${ROOT}/openshift}"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"
TEMPLATES_DIR="${KUSTOMIZE_DIR}/templates"

if ! command -v oc >/dev/null 2>&1; then
  echo "error: oc not found in PATH" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: ${ENV_FILE} not found — copy .env.example to .env and fill in values" >&2
  exit 1
fi

# Load .env (export all assignments for envsubst and oc create).
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

apply_literal_secret() {
  local secret_name="$1"
  shift
  local -a literals=("$@")
  oc create secret generic "${secret_name}" -n "${NAMESPACE}" \
    "${literals[@]}" \
    --dry-run=client -o yaml | oc apply -f -
}

echo "==> Ensuring namespace ${NAMESPACE} exists" >&2
oc apply -f "${KUSTOMIZE_DIR}/namespace.yaml"

echo "==> Applying secrets and config from ${ENV_FILE}" >&2

# URLs (defaults match openshift Service names in this overlay).
VLLM_URL="${VLLM_URL:-https://llm.example.com/v1}"
MCP_GITHUB_SSE_URL="${MCP_GITHUB_SSE_URL:-http://github-mcp:8080/}"
MCP_OPENSHIFT_SSE_URL="${MCP_OPENSHIFT_SSE_URL:-http://kubernetes-mcp:8080/sse}"
MCP_AAP_PROXY_BASE_URL="${MCP_AAP_PROXY_BASE_URL:-http://aap-mcp-proxy:8080}"
MCP_LINUX_URL="${MCP_LINUX_URL:-http://linux-mcp:8080/mcp}"
MCP_SATELLITE_URL="${MCP_SATELLITE_URL:-http://satellite-mcp:8080/mcp/sse}"
MCP_ZABBIX_URL="${MCP_ZABBIX_URL:-http://zabbix-mcp:8080/sse}"
AAP_MCP_BASE_URL="${AAP_MCP_BASE_URL:-https://aap.example.com}"
AAP_MCP_HOST="${AAP_MCP_HOST:-aap.example.com}"

AAP_PROXY="${MCP_AAP_PROXY_BASE_URL%/}"
MCP_AAP_JOB_MGMT_URL="${MCP_AAP_JOB_MGMT_URL:-${AAP_PROXY}/job_management/mcp}"
MCP_AAP_INVENTORY_MGMT_URL="${MCP_AAP_INVENTORY_MGMT_URL:-${AAP_PROXY}/inventory_management/mcp}"
MCP_AAP_SYSTEM_MONITOR_URL="${MCP_AAP_SYSTEM_MONITOR_URL:-${AAP_PROXY}/system_monitoring/mcp}"
MCP_AAP_USER_MGMT_URL="${MCP_AAP_USER_MGMT_URL:-${AAP_PROXY}/user_management/mcp}"
MCP_AAP_SECURITY_URL="${MCP_AAP_SECURITY_URL:-${AAP_PROXY}/security_compliance/mcp}"
MCP_AAP_PLATFORM_CONFIG_URL="${MCP_AAP_PLATFORM_CONFIG_URL:-${AAP_PROXY}/platform_configuration/mcp}"

VLLM_API_TOKEN="${VLLM_API_TOKEN:-fake}"
TAVILY_SEARCH_API_KEY="${TAVILY_SEARCH_API_KEY:-}"
GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
AAP_MCP_TOKEN="${AAP_MCP_TOKEN:-}"
LINUX_MCP_USER="${LINUX_MCP_USER:-}"
LINUX_MCP_KEY_PASSPHRASE="${LINUX_MCP_KEY_PASSPHRASE:-}"
SATELLITE_URL="${SATELLITE_URL:-https://satellite.example.com}"
FOREMAN_USERNAME="${FOREMAN_USERNAME:-}"
FOREMAN_TOKEN="${FOREMAN_TOKEN:-}"
ZABBIX_URL="${ZABBIX_URL:-https://zabbix.example.com}"
ZABBIX_API_TOKEN="${ZABBIX_API_TOKEN:-}"
ZABBIX_MCP_AUTH_TOKEN="${ZABBIX_MCP_AUTH_TOKEN:-}"

oc create configmap llamastack-mcp-endpoints -n "${NAMESPACE}" \
  --from-literal=VLLM_URL="${VLLM_URL}" \
  --from-literal=MCP_GITHUB_SSE_URL="${MCP_GITHUB_SSE_URL}" \
  --from-literal=MCP_OPENSHIFT_SSE_URL="${MCP_OPENSHIFT_SSE_URL}" \
  --from-literal=MCP_AAP_JOB_MGMT_URL="${MCP_AAP_JOB_MGMT_URL}" \
  --from-literal=MCP_AAP_INVENTORY_MGMT_URL="${MCP_AAP_INVENTORY_MGMT_URL}" \
  --from-literal=MCP_AAP_SYSTEM_MONITOR_URL="${MCP_AAP_SYSTEM_MONITOR_URL}" \
  --from-literal=MCP_AAP_USER_MGMT_URL="${MCP_AAP_USER_MGMT_URL}" \
  --from-literal=MCP_AAP_SECURITY_URL="${MCP_AAP_SECURITY_URL}" \
  --from-literal=MCP_AAP_PLATFORM_CONFIG_URL="${MCP_AAP_PLATFORM_CONFIG_URL}" \
  --from-literal=MCP_LINUX_URL="${MCP_LINUX_URL}" \
  --from-literal=MCP_SATELLITE_URL="${MCP_SATELLITE_URL}" \
  --from-literal=MCP_ZABBIX_URL="${MCP_ZABBIX_URL}" \
  --dry-run=client -o yaml | oc apply -f -

AAP_NGINX_TEMPLATE="${TEMPLATES_DIR}/aap-mcp-proxy-nginx.conf.template"
AAP_NGINX_TMP="$(mktemp)"
export AAP_MCP_BASE_URL AAP_MCP_HOST
envsubst '${AAP_MCP_BASE_URL} ${AAP_MCP_HOST}' < "${AAP_NGINX_TEMPLATE}" > "${AAP_NGINX_TMP}"
oc create configmap aap-mcp-proxy-nginx-template -n "${NAMESPACE}" \
  --from-file=default.conf.template="${AAP_NGINX_TMP}" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "${AAP_NGINX_TMP}"

apply_literal_secret llamastack-credentials \
  --from-literal=vllm-api-token="${VLLM_API_TOKEN}" \
  --from-literal=tavily-search-api-key="${TAVILY_SEARCH_API_KEY}"

apply_literal_secret github-mcp-pat \
  --from-literal=GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN}"

apply_literal_secret aap-mcp-credentials \
  --from-literal=AAP_MCP_TOKEN="${AAP_MCP_TOKEN}"

# Linux MCP — SSH key and config from file paths (multiline-safe).
LINUX_MCP_SSH_KEY_FILE="${LINUX_MCP_SSH_KEY_FILE:-}"
LINUX_MCP_SSH_CONFIG_FILE="${LINUX_MCP_SSH_CONFIG_FILE:-}"
if [[ -n "${LINUX_MCP_SSH_KEY_FILE}" && -f "${LINUX_MCP_SSH_KEY_FILE}" ]]; then
  linux_secret_args=(
    --from-file=id_ed25519="${LINUX_MCP_SSH_KEY_FILE}"
    --from-literal=LINUX_MCP_USER="${LINUX_MCP_USER}"
    --from-literal=LINUX_MCP_KEY_PASSPHRASE="${LINUX_MCP_KEY_PASSPHRASE}"
  )
  if [[ -n "${LINUX_MCP_SSH_CONFIG_FILE}" && -f "${LINUX_MCP_SSH_CONFIG_FILE}" ]]; then
    linux_secret_args+=(--from-file=ssh_config="${LINUX_MCP_SSH_CONFIG_FILE}")
  else
    linux_secret_args+=(--from-literal=ssh_config="# no ssh config provided")
  fi
  oc create secret generic linux-mcp-credentials -n "${NAMESPACE}" \
    "${linux_secret_args[@]}" \
    --dry-run=client -o yaml | oc apply -f -
else
  echo "warning: LINUX_MCP_SSH_KEY_FILE not set or missing — applying placeholder linux-mcp-credentials" >&2
  apply_literal_secret linux-mcp-credentials \
    --from-literal=id_ed25519="REPLACE_WITH_SSH_PRIVATE_KEY" \
    --from-literal=ssh_config="# placeholder" \
    --from-literal=LINUX_MCP_USER="${LINUX_MCP_USER}" \
    --from-literal=LINUX_MCP_KEY_PASSPHRASE="${LINUX_MCP_KEY_PASSPHRASE}"
fi

# Satellite MCP — CA bundle file optional (empty placeholder if unset).
SATELLITE_CA_FILE="${SATELLITE_CA_FILE:-}"
satellite_secret_args=(
  --from-literal=FOREMAN_USERNAME="${FOREMAN_USERNAME}"
  --from-literal=FOREMAN_TOKEN="${FOREMAN_TOKEN}"
)
if [[ -n "${SATELLITE_CA_FILE}" && -f "${SATELLITE_CA_FILE}" ]]; then
  satellite_secret_args+=(--from-file=ca.pem="${SATELLITE_CA_FILE}")
else
  satellite_secret_args+=(--from-literal=ca.pem="")
fi
oc create secret generic satellite-mcp-credentials -n "${NAMESPACE}" \
  "${satellite_secret_args[@]}" \
  --dry-run=client -o yaml | oc apply -f -

apply_literal_secret zabbix-mcp-credentials \
  --from-literal=MCP_AUTH_TOKEN="${ZABBIX_MCP_AUTH_TOKEN}"

oc create configmap satellite-mcp-config -n "${NAMESPACE}" \
  --from-literal=SATELLITE_URL="${SATELLITE_URL}" \
  --dry-run=client -o yaml | oc apply -f -

ZABBIX_CONFIG_TEMPLATE="${TEMPLATES_DIR}/zabbix-mcp-config.toml.template"
ZABBIX_CONFIG_TMP="$(mktemp)"
export ZABBIX_URL ZABBIX_API_TOKEN
envsubst '${ZABBIX_URL} ${ZABBIX_API_TOKEN}' < "${ZABBIX_CONFIG_TEMPLATE}" > "${ZABBIX_CONFIG_TMP}"
oc create configmap zabbix-mcp-config -n "${NAMESPACE}" \
  --from-file=config.toml="${ZABBIX_CONFIG_TMP}" \
  --dry-run=client -o yaml | oc apply -f -
rm -f "${ZABBIX_CONFIG_TMP}"

FSGROUP=""
for _ in $(seq 1 30); do
  FSGROUP="$(oc get namespace "${NAMESPACE}" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null | cut -d/ -f1)"
  if [[ -n "${FSGROUP}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${FSGROUP}" ]]; then
  echo "error: namespace ${NAMESPACE} has no openshift.io/sa.scc.uid-range annotation" >&2
  exit 1
fi

echo "==> Applying overlay (fsGroup=${FSGROUP})" >&2
oc kustomize "${KUSTOMIZE_DIR}" \
  | sed "s/^\([[:space:]]*fsGroup:\) [0-9][0-9]*/\1 ${FSGROUP}/" \
  | oc apply -f -

echo "==> Deployments in ${NAMESPACE}:" >&2
oc get deploy,pods -n "${NAMESPACE}"

ZABBIX_MCP_IMAGE="${ZABBIX_MCP_IMAGE:-}"
ZABBIX_MCP_GIT_REF="${ZABBIX_MCP_GIT_REF:-v1.36.1}"
if [[ -n "${ZABBIX_MCP_IMAGE}" ]]; then
  echo "==> Setting zabbix-mcp image to ZABBIX_MCP_IMAGE" >&2
  oc set image deployment/zabbix-mcp zabbix-mcp-server="${ZABBIX_MCP_IMAGE}" -n "${NAMESPACE}"
  oc rollout status deployment/zabbix-mcp -n "${NAMESPACE}" --timeout=5m
else
  echo "==> Building zabbix-mcp-server from GitHub (${ZABBIX_MCP_GIT_REF}; ghcr.io image is private)" >&2
  oc patch buildconfig zabbix-mcp-server -n "${NAMESPACE}" --type merge \
    -p "{\"spec\":{\"source\":{\"git\":{\"ref\":\"${ZABBIX_MCP_GIT_REF}\"}}}}"
  oc start-build zabbix-mcp-server -n "${NAMESPACE}" --wait
  oc rollout restart deployment/zabbix-mcp -n "${NAMESPACE}"
  oc rollout status deployment/zabbix-mcp -n "${NAMESPACE}" --timeout=5m
fi
