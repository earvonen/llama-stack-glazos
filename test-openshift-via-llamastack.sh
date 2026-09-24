#!/usr/bin/env bash
# Test GLAZOS Llama Stack → OpenShift/Kubernetes MCP (server-side Responses API).
#
# Quick check (connector tools only):
#   ./test-openshift-via-llamastack.sh --check-only
#
# Full test (list pods in a namespace via OpenShift MCP):
#   ./test-openshift-via-llamastack.sh
#   OPENSHIFT_MCP_TEST_NAMESPACE=glazos ./test-openshift-via-llamastack.sh
#
# Optional env:
#   LLAMA_STACK_BASE_URL          override Route URL
#   OPENSHIFT_NAMESPACE           default: glazos
#   LLAMA_STACK_INSECURE=0        verify TLS
#   LLAMA_STACK_MODEL             default: first vllm/ model from /v1/models
#   OPENSHIFT_CONNECTOR_ID        default: openshift
#   OPENSHIFT_MCP_TEST_NAMESPACE  default: glazos
#   MAX_INFER_ITERS               default: 10
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/test_openshift_via_llamastack.sh "$@"
