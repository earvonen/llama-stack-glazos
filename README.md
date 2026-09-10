# GLAZOS

**GLAZOS** is an OpenShift deployment for [Llama Stack](https://llamastack.github.io/) on **Red Hat OpenShift AI**, wiring a MiniMax-compatible LLM to six MCP integrations:

| Letter | Integration |
|--------|-------------|
| **G** | **GitHub** — in-cluster MCP (`ghcr.io/github/github-mcp-server`) |
| **L** | **Linux (RHEL)** — in-cluster Red Hat `linux-mcp-server` |
| **A** | **Ansible** (Automation Platform) — six external AAP MCP toolsets (direct HTTPS from Llama Stack) |
| **Z** | **Zabbix** — in-cluster initMAX `zabbix-mcp-server` |
| **O** | **OpenShift** / Kubernetes — in-cluster `kubernetes-mcp-server` |
| **S** | **Satellite** — in-cluster `foreman-mcp-server` |

Also enabled: **web search** (Tavily, `builtin::websearch`) and **external inference** via a vLLM-compatible endpoint (`VLLM_URL` in `.env`).

Default namespace: **`glazos`**.

## Prerequisites

1. RHOAI with Llama Stack operator enabled (`DataScienceCluster` → `llamastackoperator: Managed`).
2. `registry.redhat.io` pull secret for RHOAI and Satellite MCP image.
3. Network path from the cluster to your LLM Route, AAP MCP host, Satellite, Zabbix, and Linux SSH targets.
4. Copy `.env.example` to `.env` and fill in URLs, tokens, and file paths ([secrets/README.md](secrets/README.md)).

## Repository layout

| Path | Purpose |
|------|---------|
| `openshift/kustomization.yaml` | Kustomize entrypoint |
| `openshift/config/config.yaml` | Llama Stack stack config (inference, web search, connectors) |
| `openshift/llamastackdistribution.yaml` | RHOAI `LlamaStackDistribution` CR |
| `openshift/templates/` | Config templates rendered from `.env` at deploy time |
| `openshift/github-mcp.yaml` | GitHub MCP + nginx PAT injection |
| `openshift/kubernetes-mcp.yaml` | OpenShift/Kubernetes MCP + RBAC |
| `openshift/linux-mcp.yaml` | Red Hat Linux MCP (HTTP + SSH) |
| `openshift/satellite-mcp.yaml` | Satellite MCP + nginx Foreman header injection |
| `openshift/zabbix-mcp.yaml` | Zabbix MCP + nginx Bearer injection |
| `deploy-openshift.sh` | Deploy with OpenShift `fsGroup` patching; AAP CA trust Secret; legacy proxy cleanup |
| `scripts/patch_llamastack_aap_mcp.py` | Startup patch for Llama Stack 0.7.x + AAP streamable-http MCP (mounted via ConfigMap) |
| `test-zabbix-via-llamastack.sh` | Verify Llama Stack → Zabbix MCP (connector tools + optional chat) |
| `test-aap-via-llamastack.sh` | Verify Llama Stack → AAP MCP (connector tools + Responses API job listing) |
| `secrets/README.md` | `.env` variables and rotation notes |

## Configure before deploy

1. **`.env`** — `cp .env.example .env` and set all URLs, tokens, and file paths.
2. **External AAP MCP** — set `AAP_MCP_BASE_URL`, `AAP_MCP_TOKEN`, and `AAP_MCP_CA_DIR` (or `AAP_MCP_CA_FILE`) when AAP uses a private CA. See [secrets/README.md](secrets/README.md#aap-mcp-token-and-tls-trust).

Removed from the default overlay: in-cluster **`aap-mcp-proxy`** (nginx). Llama Stack calls AAP MCP toolsets over HTTPS directly. Legacy manifests remain under `openshift/aap-mcp-proxy.yaml` for reference only.

## Deploy

```bash
cp .env.example .env   # first time only
# edit .env
./deploy-openshift.sh
```

Override namespace: `OPENSHIFT_NAMESPACE=my-ns ./deploy-openshift.sh`

MCP connectors and web search are declared in `openshift/config/config.yaml` (`connectors` section) and pick up MCP URLs from the `llamastack-mcp-endpoints` ConfigMap at startup — no separate registration step.

## Verify

```bash
oc get pods -n glazos
oc get route llamastack -n glazos -o jsonpath='{.spec.host}{"\n"}'
```

From the Llama Stack pod, test MCP reachability:

```bash
oc exec -n glazos deploy/llamastack -- curl -sS -o /dev/null -w "%{http_code}\n" http://github-mcp:8080/
source .env && oc exec -n glazos deploy/llamastack -- curl -sk -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer ${AAP_MCP_TOKEN}" "${AAP_MCP_BASE_URL}/job_management/mcp"
```

Confirm model id (`VLLM_URL` from `.env`):

```bash
source .env && curl -sk "${VLLM_URL}/models"
```

Use chat model id `vllm/<model-id-from-vllm>`.

### Integration tests

```bash
# Zabbix — connector tools and optional Responses API query
./test-zabbix-via-llamastack.sh --check-only

# AAP — all six connectors (requires AAP_MCP_TOKEN in .env)
./test-aap-via-llamastack.sh --check-only --all-connectors

# AAP — full Responses API test (lists recent jobs via aap-jobs)
./test-aap-via-llamastack.sh
```

AAP tests pass the raw MCP token as `?authorization=` on connector API calls and in `tools[].authorization` for `/v1/responses` (Llama Stack adds the `Bearer` prefix upstream).

## AAP MCP notes (Llama Stack 0.7.x)

External AAP MCP uses **streamable HTTP**, not SSE. RHOAI Llama Stack 0.7.3 has bugs around duplicate MCP `initialize` and missing auth on connector resolution. This repo applies a **startup patch** (`scripts/patch_llamastack_aap_mcp.py`, ConfigMap `llamastack-mcp-patch`) before the server starts.

For TLS to a privately signed AAP MCP endpoint, `deploy-openshift.sh` (at the end of deploy):

1. Merges your signing CA from `AAP_MCP_CA_DIR` / `AAP_MCP_CA_FILE` with the operator CA bundle.
2. Stores the result in Secret `llamastack-aap-mcp-trust`.
3. Mounts it at `/etc/ssl/certs/aap-merged-ca-bundle.crt` and sets `SSL_CERT_FILE` in the Llama Stack startup command.

The CA file must be the **signing CA** (`CA:TRUE`), not the AAP server/end-entity certificate.

## References

- [Working with Llama Stack (RHOAI 3.4)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/working_with_llama_stack/)
- [Linux MCP Server](https://rhel-lightspeed.github.io/linux-mcp-server/)
- [Satellite MCP](https://docs.redhat.com/en/documentation/red_hat_satellite/6.19/html/managing_hosts/connecting-ai-applications-to-the-mcp-server-for-satellite)
- [AAP MCP](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/extend-assembly_deploying_ansible_mcp_server)
- [Zabbix MCP Server](https://github.com/initMAX/zabbix-mcp-server)
