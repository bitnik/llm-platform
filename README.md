# llm-platform

A POC for a **self-hosted LLM platform on K3s**:

* GPU inference with [vLLM](https://docs.vllm.ai/) behind a [LiteLLM](https://docs.litellm.ai/) gateway
* GitOps-managed with [Flux](https://fluxcd.io/),
* secrets encrypted with [SOPS](https://getsops.io/) and [age](https://github.com/FiloSottile/age).

## Hardware

Single [Hetzner GEX44](https://www.hetzner.com/dedicated-rootserver/gex44/) dedicated server:
NVIDIA **RTX 4000 SFF Ada**, 20 GB VRAM, Ubuntu 24.04, single-node K3s.

## Architecture

This diagram shows the **target** design, see [Roadmap](#roadmap) for the parts not built yet.

```txt
                  DEV LAPTOPS (external)                           IN-CLUSTER
        ┌──────────────┬──────────────┬──────────────-┐              ┌─--─────┐
        │ Claude Code  │  kubectl-ai  │   k8sgpt CLI  │              │ kagent |
        └─────┬────────┴──────┬───────┴───────┬───────┘            ┌-└──-┬--──┘-┐
              │  Anthropic    │ OpenAI        │                    │ OpenAI     │
              └───────────────┴───────┬───────┘                    └─────┬──────┘
                                      ▼ (HTTPS)                          │ (ClusterIP)
                          ┌────────────────────-───┐                     │
                          │ Ingress                │                     │
                          └───────────┬────────────┘                     │
                                      ▼                                  ▼
              ╔══════════════════════════════════════════════════════====════════════================╗
              ║ LiteLLM Proxy  (gateway) - routes by model name                                      ║
              ║                          - implements per-userkeys, budget, rate-limit, logging      ║
              ║   "gpt-oss" ─┐         "qwen" ─-┐                                                    ║
              ╚═══════════╪═════════════════════╪════════════════════════════════════================╝
                          │                     │
                          │   OpenAI protocol   │
                          ▼                     ▼
              ╔═════════════════════════════════════════════════════════════════==═===╗
              ║ MODEL SERVING via vLLM (one physical GPU, one model active at a time) ║
              ║                                                                       ║
              ║   ┌─────────────────────┐        ┌─────────────────────┐              ║
              ║   │ vLLM: gpt-oss-20b   │        │ vLLM: Qwen3.6-27B   │              ║
              ║   │  ● ACTIVE           │        │  ○ SLEEPING (L1)    │              ║
              ║   │  weights → VRAM     │        │  weights → RAM      │              ║
              ║   │  holds gpu:1        │        │  0 VRAM used        │              ║
              ║   └──────────┬──────────┘        └──────────▲──────────┘              ║
              ║              │                              │                         ║
              ║              ▼            ┌─────────────────┴──────────┐              ║
              ║        [ 20 GB VRAM ]◄────┤ switch controller          │              ║
              ║                           │ POST /sleep · /wake_up     │              ║
              ║                           │ (in-cluster only, locked)  │              ║
              ╚═══════════════╤═══════════╧════════════════╤═══════════════════════===╝
                              │ mounts                     │ scrape
                              ▼                            ▼
              ┌───────────────────────────┐   ┌──────────────────────────────┐
              │ local-path PVC (NVMe)     │   │ Prometheus & Grafana & OTel  │
              │ ALL model weights (cold)  │   │                              │
              └───────────────────────────┘   └──────────────────────────────┘
```

## Repository layout

```txt
bootstrap/              Node and cluster setup guide (see below)
clusters/llm-platform/  Flux entrypoint (GitRepository + Kustomizations)
deploy/                 Apps reconciled by Flux:
  ├─ cert-manager/         TLS certificate controller
  ├─ cert-manager-issuers/ Let's Encrypt ClusterIssuers
  ├─ gpu-operator/         NVIDIA GPU Operator (device plugin, DCGM)
  ├─ vllm-stack/           vLLM model serving
  └─ litellm/              LiteLLM gateway
tofu/litellm/           LiteLLM teams/users/keys/budgets managed with OpenTofu
.sops.yaml              SOPS rules (age recipients allowed to decrypt)
justfile                Task runner, run `just` to list targets
```

## Bootstrap

First-time setup of the GPU node
(NVIDIA driver -> container toolkit -> K3s -> GPU Operator -> Flux) is documented in
[bootstrap/README.md](bootstrap/README.md).


## Deploy (GitOps)

[Flux](https://fluxcd.io/) watches this repo **main** branch and reconciles the cluster to match it.
The entrypoint is [`clusters/llm-platform`](clusters/llm-platform),
which applies the apps under [`deploy/`](deploy) (decrypting SOPS secrets with the in-cluster age key).

```sh
# reconciliation status
flux get kustomizations -A
# reconcile a kustomization now
flux reconcile kustomization flux-system --with-source
flux reconcile kustomization deploy --with-source
# List what's managed by this kustomization
flux tree kustomization deploy
```

> Other ways to run vLLM on k8s: https://docs.vllm.ai/en/stable/deployment/k8s/

## Development

Install:

* [`just`](https://github.com/casey/just) (task runner),
* [`pre-commit`](https://pre-commit.com/),
* [`sops`](https://getsops.io/) and [`age`](https://github.com/FiloSottile/age) (for secrets),
* [`flux`](https://fluxcd.io/flux/installation/) and `kubectl` (for cluster management),
* [`tofu`](https://opentofu.org/docs/intro/install/) (for LiteLLM access management).

Run `just` to see all targets.

### Pre-commit hooks

[`pre-commit`](https://pre-commit.com/) guards every commit.
Config lives in [`.pre-commit-config.yaml`](.pre-commit-config.yaml).

```sh
# one-time: install the pre-commit git hook
pre-commit install
# run all hooks against all files
pre-commit run --all-files
# just pre-commit
# auto-format YAML files
just yamlfmt
```

### Secrets

Encrypted files match `*.enc.*` (rules in [`.sops.yaml`](.sops.yaml)).
To work with them,

* add your **age public key** to `.sops.yaml` and
* have an existing recipient re-encrypt, or get added to the cluster's `sops-age` secret.

```sh
# To edit an encrypted file in-place
# decrypt → $EDITOR → re-encrypt
just edit deploy/litellm/config.enc.yaml
# fail if any plaintext secret slipped in
just check
```

### Connect to the cluster

```sh
NODEIP=""
# start ssh tunnel
ssh -L 16443:127.0.0.1:6443 root@$NODEIP
# download kubeconfig and use localhost for kubeapiserver
scp root@$NODEIP:/etc/rancher/k3s/k3s.yaml ~/.kube/llm-platform.yaml
sed -i 's#127.0.0.1:6443#127.0.0.1:16443#' ~/.kube/llm-platform.yaml
sed -i 's/default/llm-platform/g' ~/.kube/llm-platform.yaml

# Now you can use kubectl and flux locally
flux get all -A
kubectl get gitrepositories,kustomizations,helmreleases -A
```

## Usage

The LiteLLM gateway is reachable over HTTPS via Ingress.
Authenticate with a LiteLLM key.
Personal / workload keys (with budgets and rate-limits) are managed with OpenTofu,
see [tofu/litellm](tofu/litellm).

Accessing LiteLLM via UI:

```sh
kubectl -n litellm port-forward svc/litellm 4000:4000
# and then open http://localhost:4000/ui/ in your browser
# to login use the following credentials
# username:
just extract deploy/litellm/config.enc.yaml '.stringData["values.yaml"]' | yq '.envVars.UI_USERNAME'
# or
# kubectl get secret -n litellm litellm-values -o yaml | yq '.data["values.yaml"]' | base64 -d | yq '.envVars.UI_USERNAME'
# password:
just extract deploy/litellm/config.enc.yaml '.stringData["values.yaml"]' | yq '.envVars.UI_PASSWORD'
# or
# kubectl get secret -n litellm litellm-values -o yaml | yq '.data["values.yaml"]' | base64 -d | yq '.envVars.UI_PASSWORD'
```

Accessing LiteLLM via API:

```sh
# First generate a key using [tofu/litellm](tofu/litellm)
LITELLM_KEY=""
LITELLM_KEY=$(just tofu output -json keys | jq -r .bitnik)
# You can also use the masterkey secret (not recommended)
# LITELLM_KEY=$(kubectl -n litellm get secret litellm-masterkey -o jsonpath='{.data.masterkey}' | base64 -d)
URL=$(kubectl get ingress -n litellm litellm -o yaml | yq '.spec.tls.0.hosts.0')

# list available models
curl -s https://$URL/v1/models -H "Authorization: Bearer $LITELLM_KEY" | jq '.data[].id'
# MODEL="gpt-oss-20b"
MODEL="devstral-small-2-24b-awq-4bit"

# OpenAI protocol
curl -s https://$URL/v1/chat/completions -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"'"$MODEL"'","max_tokens":300,"messages":[{"role":"user","content":"reply with one short sentence"}]}' | jq

# Anthropic protocol
curl -s https://$URL/v1/messages -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'content-type: application/json' \
  -d '{"model":"'"$MODEL"'","max_tokens":300,"messages":[{"role":"user","content":"Explain what Kubernetes is in two sentences."}]}' | jq

# Set reasoning_effort low here (the litellm config default is high).
# NOTE: Devstral Small 2 is not a reasoning model. So this won't have an effect. It is just here as an example.

# Set reasoning_effort low (litellm config defaults to high).
# NOTE: Devstral Small 2 is not a reasoning model, so this has no effect,
# since drop_params is true,
# so litellm strips the param before it reaches the model.
# Left here only as an example.
curl -s https://$URL/v1/messages -H "Authorization: Bearer $LITELLM_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "'"$MODEL"'",
    "messages": [{"role":"user","content":"Explain what Kubernetes is in two sentences."}],
    "reasoning_effort": "low",
    "max_tokens": 1024
  }' | jq
```

## Roadmap

- [x] Observability: kube-prometheus-stack, DCGM, vLLM, LiteLLM metrics, grafana dashboards
- [x] Validate with kagent (in-cluster), kubectl-ai, k8sgpt, Claude Code, pi agent
- [x] Configure LiteLLM users, keys, budgets, rate-limits with OpenTofu + [terraform-provider-litellm](https://github.com/ncecere/terraform-provider-litellm), see [tofu/litellm](tofu/litellm)
- [ ] OTel for traces + enable alerts
- [ ] Automated E2E tests in GitHub Actions (reliability checks). Add a “sleep" API test (Validate that  the PVC hot-load switch works).
- [ ] Second model + sleep/wake VRAM switching (See https://docs.vllm.ai/projects/production-stack/en/latest/use_cases/sleep-wakeup-mode.html)
