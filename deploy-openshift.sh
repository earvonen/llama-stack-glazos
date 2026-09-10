#!/usr/bin/env bash
# Deploy GLAZOS OpenShift overlay. Secrets, URLs, and ConfigMaps are applied from .env
# (see .env.example). Default namespace: glazos. At the end, merges AAP MCP signing CA
# (AAP_MCP_CA_DIR / AAP_MCP_CA_FILE) into Secret llamastack-aap-mcp-trust when configured.
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
MCP_LINUX_URL="${MCP_LINUX_URL:-http://linux-mcp:8080/mcp}"
MCP_SATELLITE_URL="${MCP_SATELLITE_URL:-http://satellite-mcp:8080/mcp/sse}"
MCP_ZABBIX_URL="${MCP_ZABBIX_URL:-http://zabbix-mcp:8080/sse}"
AAP_MCP_BASE_URL="${AAP_MCP_BASE_URL:-https://aap.example.com}"
AAP_MCP_HOST="${AAP_MCP_HOST:-aap.example.com}"

# Llama Stack calls external AAP MCP toolsets directly (Bearer token from AAP_MCP_TOKEN on the pod).
AAP_MCP_DIRECT_BASE="${AAP_MCP_BASE_URL%/}"
MCP_AAP_JOB_MGMT_URL="${MCP_AAP_JOB_MGMT_URL:-${AAP_MCP_DIRECT_BASE}/job_management/mcp}"
MCP_AAP_INVENTORY_MGMT_URL="${MCP_AAP_INVENTORY_MGMT_URL:-${AAP_MCP_DIRECT_BASE}/inventory_management/mcp}"
MCP_AAP_SYSTEM_MONITOR_URL="${MCP_AAP_SYSTEM_MONITOR_URL:-${AAP_MCP_DIRECT_BASE}/system_monitoring/mcp}"
MCP_AAP_USER_MGMT_URL="${MCP_AAP_USER_MGMT_URL:-${AAP_MCP_DIRECT_BASE}/user_management/mcp}"
MCP_AAP_SECURITY_URL="${MCP_AAP_SECURITY_URL:-${AAP_MCP_DIRECT_BASE}/security_compliance/mcp}"
MCP_AAP_PLATFORM_CONFIG_URL="${MCP_AAP_PLATFORM_CONFIG_URL:-${AAP_MCP_DIRECT_BASE}/platform_configuration/mcp}"

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

apply_literal_secret llamastack-credentials \
  --from-literal=vllm-api-token="${VLLM_API_TOKEN}" \
  --from-literal=tavily-search-api-key="${TAVILY_SEARCH_API_KEY}"

apply_literal_secret github-mcp-pat \
  --from-literal=GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN}"

apply_literal_secret aap-mcp-credentials \
  --from-literal=AAP_MCP_TOKEN="${AAP_MCP_TOKEN}"

# Legacy in-cluster AAP nginx proxy (removed from kustomization; delete if still present).
oc delete deployment/aap-mcp-proxy service/aap-mcp-proxy route/aap-mcp-proxy \
  configmap/aap-mcp-proxy-nginx-template -n "${NAMESPACE}" --ignore-not-found

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

# External AAP MCP uses a private CA in many lab installs. Merge the signing CA from
# AAP_MCP_CA_DIR / AAP_MCP_CA_FILE into Secret llamastack-aap-mcp-trust and reconcile
# the LlamaStackDistribution (CA mount + startup patch are in llamastackdistribution.yaml).
AAP_MCP_CA_DIR="${AAP_MCP_CA_DIR:-}"
AAP_MCP_CA_FILE="${AAP_MCP_CA_FILE:-}"

resolve_aap_mcp_ca_path() {
  if [[ -n "${AAP_MCP_CA_FILE}" && -f "${AAP_MCP_CA_FILE}" ]]; then
    printf '%s' "${AAP_MCP_CA_FILE}"
    return 0
  fi
  if [[ -n "${AAP_MCP_CA_DIR}" && -d "${AAP_MCP_CA_DIR}" ]]; then
    if [[ -f "${AAP_MCP_CA_DIR}/ca.crt" ]]; then
      printf '%s' "${AAP_MCP_CA_DIR}/ca.crt"
      return 0
    fi
    if [[ -f "${AAP_MCP_CA_DIR}/ca.pem" ]]; then
      printf '%s' "${AAP_MCP_CA_DIR}/ca.pem"
      return 0
    fi
  fi
  return 1
}

aap_ca_already_in_bundle() {
  local bundle="$1"
  local ca="$2"
  local target_fp dir cert
  target_fp="$(openssl x509 -in "${ca}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  [[ -n "${target_fp}" ]] || return 1
  dir="$(mktemp -d)"
  awk '/-----BEGIN CERTIFICATE-----/{i++}{print > ("'"${dir}"'/cert-" i ".pem")}' "${bundle}"
  for cert in "${dir}"/cert-*.pem; do
    [[ -f "${cert}" ]] || continue
    fp="$(openssl x509 -in "${cert}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
    if [[ "${fp}" == "${target_fp}" ]]; then
      rm -rf "${dir}"
      return 0
    fi
  done
  rm -rf "${dir}"
  return 1
}

apply_aap_mcp_ca_trust() {
  local ca_path current merged llama_image
  ca_path="$(resolve_aap_mcp_ca_path || true)"
  if [[ -z "${ca_path}" ]]; then
    echo "warning: AAP MCP CA not configured — set AAP_MCP_CA_DIR or AAP_MCP_CA_FILE in .env" >&2
    return 0
  fi

  if openssl x509 -in "${ca_path}" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
    echo "    using signing CA: $(openssl x509 -in "${ca_path}" -noout -subject 2>/dev/null | sed 's/^subject=//')" >&2
  else
    echo "warning: ${ca_path} is not marked CA:TRUE — expected the AAP signing CA PEM" >&2
  fi

  echo "==> Appending AAP MCP CA to llamastack trust Secret" >&2
  current="$(mktemp)"
  merged="$(mktemp)"
  llama_image="${LLAMASTACK_IMAGE:-registry.redhat.io/rhoai/odh-llama-stack-core-rhel9:v3.4}"

  if oc get configmap llamastack-ca-bundle -n "${NAMESPACE}" >/dev/null 2>&1; then
    oc get configmap llamastack-ca-bundle -n "${NAMESPACE}" -o jsonpath='{.data.ca-bundle\.crt}' >"${current}"
  elif oc exec -n "${NAMESPACE}" deploy/llamastack -- cat /etc/ssl/certs/ca-bundle/ca-bundle.crt >"${current}" 2>/dev/null; then
    :
  else
    echo "warning: llamastack pod unavailable — extracting system CA bundle via temporary pod" >&2
    oc run aap-ca-bundle-extract -n "${NAMESPACE}" --rm -i --restart=Never \
      --image="${llama_image}" \
      --overrides="$(jq -n --arg img "${llama_image}" '{
        spec: {
          containers: [{
            name: "aap-ca-bundle-extract",
            image: $img,
            command: ["cat", "/etc/pki/tls/certs/ca-bundle.crt"],
            stdin: false,
            tty: false
          }]
        }
      }')" \
      >"${current}"
  fi

  if aap_ca_already_in_bundle "${current}" "${ca_path}"; then
    echo "    AAP MCP CA already present in bundle source — skipping append" >&2
    cp "${current}" "${merged}"
  else
    cat "${current}" "${ca_path}" >"${merged}"
  fi

  oc delete secret llamastack-aap-mcp-trust -n "${NAMESPACE}" --ignore-not-found
  oc create secret generic llamastack-aap-mcp-trust -n "${NAMESPACE}" \
    --from-file=ca-bundle.crt="${merged}"
  rm -f "${current}" "${merged}"

  echo "==> Applying LlamaStackDistribution with AAP CA trust mount" >&2
  oc apply -f "${KUSTOMIZE_DIR}/llamastackdistribution.yaml"
  oc rollout status deployment/llamastack -n "${NAMESPACE}" --timeout=5m
}

apply_aap_mcp_ca_trust
