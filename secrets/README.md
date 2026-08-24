# GLAZOS configuration

Credentials and **URLs** for GLAZOS are not stored in the Kustomize overlay. `deploy-openshift.sh` reads **`.env`** at the project root and applies Secrets and ConfigMaps before the rest of the overlay.

Default OpenShift namespace: **`glazos`** (`OPENSHIFT_NAMESPACE` to override).

## Setup

```bash
cp .env.example .env
# Edit .env with URLs, tokens, and file paths
./deploy-openshift.sh
```

`.env` is gitignored. Never commit real credentials.

## Variables in `.env`

### URLs

| Variable | Purpose |
|----------|---------|
| `VLLM_URL` | MiniMax / vLLM OpenAI base URL (must end with `/v1`) |
| `MCP_GITHUB_SSE_URL` | In-cluster GitHub MCP (Llama Stack connector) |
| `MCP_OPENSHIFT_SSE_URL` | In-cluster Kubernetes MCP (SSE) |
| `MCP_AAP_PROXY_BASE_URL` | In-cluster AAP nginx proxy base URL |
| `MCP_LINUX_URL` | In-cluster Linux MCP |
| `MCP_SATELLITE_URL` | In-cluster Satellite MCP |
| `MCP_ZABBIX_URL` | In-cluster Zabbix MCP |
| `AAP_MCP_BASE_URL` | External AAP MCP upstream (nginx `proxy_pass`) |
| `AAP_MCP_HOST` | Host header for external AAP (`proxy_set_header Host`) |
| `SATELLITE_URL` | External Satellite / Foreman API URL |
| `ZABBIX_URL` | External Zabbix API URL |

Optional overrides for individual AAP toolset connector URLs (default: `${MCP_AAP_PROXY_BASE_URL}/<toolset>/mcp`):

- `MCP_AAP_JOB_MGMT_URL`, `MCP_AAP_INVENTORY_MGMT_URL`, `MCP_AAP_SYSTEM_MONITOR_URL`, `MCP_AAP_USER_MGMT_URL`, `MCP_AAP_SECURITY_URL`, `MCP_AAP_PLATFORM_CONFIG_URL`

`llama-stack-preparation.sh` uses the same `.env` URL variables for tool group registration.

### Credentials

| Variable | Used for |
|----------|----------|
| `VLLM_API_TOKEN` | Llama Stack → MiniMax LLM (default `fake`) |
| `TAVILY_SEARCH_API_KEY` | Web search (`builtin::websearch`) |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub MCP (raw PAT, no `Bearer `) |
| `AAP_MCP_TOKEN` | AAP MCP proxy (raw token) |
| `LINUX_MCP_USER` | Linux MCP SSH user |
| `LINUX_MCP_KEY_PASSPHRASE` | Optional SSH key passphrase |
| `LINUX_MCP_SSH_KEY_FILE` | Path to private key file on deploy host |
| `LINUX_MCP_SSH_CONFIG_FILE` | Optional path to ssh config file |
| `FOREMAN_USERNAME` | Satellite MCP auth header |
| `FOREMAN_TOKEN` | Satellite personal access token |
| `SATELLITE_CA_FILE` | Optional path to Satellite CA PEM file |
| `ZABBIX_API_TOKEN` | Zabbix API token (MCP server config) |
| `ZABBIX_MCP_AUTH_TOKEN` | Bearer token for Zabbix MCP HTTP auth |

Multiline values (SSH keys, CA bundles) use **file paths** on the machine running `deploy-openshift.sh`.

## Rotate exposed tokens

If a token was shared in chat or email, rotate it on the source system before updating `.env`.

## AAP MCP token

- Raw token only (no `Bearer ` prefix).
- The in-cluster `aap-mcp-proxy` nginx sidecar adds `Authorization: Bearer …` when calling `AAP_MCP_BASE_URL`.

## GitHub PAT

- Raw token only (`ghp_…`, `github_pat_…`). nginx adds the Bearer prefix.

## Linux MCP SSH key

- Container runs as UID 1001. Key is mounted from Secret key `id_ed25519`.
- Ensure NetworkPolicy allows SSH egress from the `linux-mcp` pod to target hosts.
