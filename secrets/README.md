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
| `MCP_GITHUB_SSE_URL` | In-cluster GitHub MCP (OGX connector) |
| `MCP_OPENSHIFT_SSE_URL` | In-cluster Kubernetes MCP (SSE) |
| `MCP_LINUX_URL` | In-cluster Linux MCP |
| `MCP_SATELLITE_URL` | In-cluster Satellite MCP (streamable-http: `http://satellite-mcp:8080/mcp`) |
| `MCP_ZABBIX_URL` | In-cluster Zabbix MCP |
| `AAP_MCP_BASE_URL` | External AAP MCP base URL (OGX calls `<base>/<toolset>/mcp` directly) |
| `AAP_MCP_HOST` | Legacy: hostname for removed in-cluster `aap-mcp-proxy` nginx template |
| `SATELLITE_URL` | External Satellite / Foreman API URL |
| `ZABBIX_URL` | External Zabbix API URL |

Optional overrides for individual AAP toolset connector URLs (default: `${AAP_MCP_BASE_URL}/<toolset>/mcp`):

- `MCP_AAP_JOB_MGMT_URL`, `MCP_AAP_INVENTORY_MGMT_URL`, `MCP_AAP_SYSTEM_MONITOR_URL`, `MCP_AAP_USER_MGMT_URL`, `MCP_AAP_SECURITY_URL`, `MCP_AAP_PLATFORM_CONFIG_URL`

Those env vars feed `connectors` in `openshift/config/config.yaml` at OGX startup.

### Credentials

| Variable | Used for |
|----------|----------|
| `LLAMA_STACK_API_TOKEN` | Bearer token required by the OGX HTTP API (`Authorization: Bearer …`) |
| `VLLM_API_TOKEN` | OGX → MiniMax LLM (default `fake`) |
| `TAVILY_SEARCH_API_KEY` | Web search (`builtin::websearch`) |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | GitHub MCP (raw PAT, no `Bearer `) |
| `AAP_MCP_TOKEN` | External AAP MCP Bearer token (on OGX pod; pass as `authorization` on MCP API calls) |
| `AAP_MCP_CA_DIR` | Directory on the **deploy host** with `ca.crt` (signing CA for AAP MCP TLS) |
| `AAP_MCP_CA_FILE` | Optional PEM file path on the deploy host instead of `AAP_MCP_CA_DIR` |
| `LINUX_MCP_USER` | Linux MCP SSH user |
| `LINUX_MCP_KEY_PASSPHRASE` | Optional SSH key passphrase |
| `LINUX_MCP_SSH_KEY_FILE` | Path to private key file on deploy host |
| `LINUX_MCP_SSH_CONFIG_FILE` | Optional path to ssh config file |
| `FOREMAN_USERNAME` | Satellite MCP auth header |
| `FOREMAN_TOKEN` | Satellite personal access token |
| `SATELLITE_CA_FILE` | Optional path to Satellite CA PEM file |
| `ZABBIX_API_TOKEN` | Zabbix API token (written into `zabbix-mcp-config` ConfigMap as `config.toml`) |
| `ZABBIX_MCP_AUTH_TOKEN` | Bearer token for Zabbix MCP HTTP auth (`zabbix-mcp-credentials` Secret) |

Multiline values (SSH keys, CA bundles) use **file paths** on the machine running `deploy-openshift.sh`.

## Rotate exposed tokens

If a token was shared in chat or email, rotate it on the source system before updating `.env`.

## AAP MCP token, TLS trust, and startup patch

AAP MCP servers run **outside GLAZOS**. This section only covers the OGX **client** wiring.

- Raw token only (no `Bearer ` prefix).
- Stored in Secret `aap-mcp-credentials` and mounted on the OGX pod as `AAP_MCP_TOKEN`.
- OGX connector URLs point at `${AAP_MCP_BASE_URL}/<toolset>/mcp`. Pass the token when calling MCP:
  - `GET /v1/connectors/<aap-*>/tools?authorization=<token>`
  - `POST /v1/responses` with `tools[].authorization` for MCP tool entries.
- **TLS:** set `AAP_MCP_CA_DIR` (directory containing a PEM such as `ca.crt`) or `AAP_MCP_CA_FILE`. The file must be the **signing CA certificate** that issued the AAP MCP server cert (`CA:TRUE`), not the server/end-entity certificate. At the end of deploy, `deploy-openshift.sh` merges it with the operator CA bundle into Secret `llamastack-aap-mcp-trust`, mounted at `/etc/ssl/certs/aap-merged-ca-bundle.crt`, and sets `SSL_CERT_FILE` in the OGX startup command (`openshift/ogxserver.yaml`).
- **Streamable HTTP patch:** AAP MCP does not support SSE. ConfigMap `llamastack-mcp-patch` (from `scripts/patch_llamastack_aap_mcp.py`) is mounted into the pod and applied at startup before `ogx run`. AAP-related snippets are best-effort (skipped if already fixed in the OGX image). The Glazos default Responses `instructions` injection is required. Drop the AAP workarounds once the RHOAI OGX image no longer needs them.

Verify with `./test-aap-via-llamastack.sh --check-only --all-connectors`.

## GitHub PAT

- Raw token only (`ghp_…`, `github_pat_…`). nginx adds the Bearer prefix.

## Linux MCP SSH key

- Container runs as UID 1001. Key is mounted from Secret key `id_ed25519`.
- Ensure NetworkPolicy allows SSH egress from the `linux-mcp` pod to target hosts.
