# GLAZOS

**GLAZOS** is an OpenShift deployment for [Llama Stack](https://llamastack.github.io/) on **Red Hat OpenShift AI**, wiring a MiniMax-compatible LLM to six MCP integrations:

| Letter | Integration |
|--------|-------------|
| **G** | **GitHub** — in-cluster MCP (`ghcr.io/github/github-mcp-server`) |
| **L** | **Linux (RHEL)** — in-cluster Red Hat `linux-mcp-server` |
| **A** | **Ansible** (Automation Platform) — external AAP MCP via in-cluster nginx auth proxy |
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
| `openshift/aap-mcp-proxy.yaml` | nginx proxy to external Ansible AAP MCP |
| `openshift/linux-mcp.yaml` | Red Hat Linux MCP (HTTP + SSH) |
| `openshift/satellite-mcp.yaml` | Satellite MCP + nginx Foreman header injection |
| `openshift/zabbix-mcp.yaml` | Zabbix MCP + nginx Bearer injection |
| `deploy-openshift.sh` | Deploy with OpenShift `fsGroup` patching |
| `test-zabbix-via-llamastack.sh` | Verify Llama Stack → Zabbix MCP (connector tools + optional chat) |
| `secrets/README.md` | `.env` variables and rotation notes |

## Configure before deploy

1. **`.env`** — `cp .env.example .env` and set all URLs, tokens, and file paths.

## Deploy

```bash
cp .env.example .env   # first time only
# edit .env
./deploy-openshift.sh
```

Override namespace: `OPENSHIFT_NAMESPACE=my-ns ./deploy-openshift.sh`

MCP tool groups and web search are declared in `openshift/config/config.yaml` (`tool_groups` section) and pick up MCP URLs from the `llamastack-mcp-endpoints` ConfigMap at startup — no separate registration step.

## Verify

```bash
oc get pods -n glazos
oc get route llamastack -n glazos -o jsonpath='{.spec.host}{"\n"}'
```

From the Llama Stack pod, test MCP reachability:

```bash
oc exec -n glazos deploy/llamastack -- curl -sS -o /dev/null -w "%{http_code}\n" http://github-mcp:8080/
oc exec -n glazos deploy/llamastack -- curl -sS -o /dev/null -w "%{http_code}\n" http://aap-mcp-proxy:8080/job_management/mcp
```

Confirm model id (`VLLM_URL` from `.env`):

```bash
source .env && curl -sk "${VLLM_URL}/models"
```

Use chat model id `vllm/<model-id-from-vllm>`.

## References

- [Working with Llama Stack (RHOAI 3.4)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/working_with_llama_stack/)
- [Linux MCP Server](https://rhel-lightspeed.github.io/linux-mcp-server/)
- [Satellite MCP](https://docs.redhat.com/en/documentation/red_hat_satellite/6.19/html/managing_hosts/connecting-ai-applications-to-the-mcp-server-for-satellite)
- [AAP MCP](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/extend-assembly_deploying_ansible_mcp_server)
- [Zabbix MCP Server](https://github.com/initMAX/zabbix-mcp-server)
