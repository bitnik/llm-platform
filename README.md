# llm-platform

This is a POC for a self-hosted LLM platform on K3s - GPU inference with vLLM behind a LiteLLM gateway, cloud-native agent tooling, GitOps-managed.

## Machine

https://www.hetzner.com/dedicated-rootserver/gex44/

## System Diagram

```txt
                  DEV LAPTOPS (external)                           IN-CLUSTER
        ┌──────────────┬──────────────┬──────────────-┐              ┌─--─────┐
        │ Claude Code  │  kubectl-ai  │   k8sgpt CLI  │              │ kagent |   
        └──────┬───────┴──────┬───────┴───────┬───────┘            ┌-└──-┬--──┘-┐
               │ Anthropic    │ OpenAI        │                    │ OpenAI     │
               └──────────────┴───────┬───────┘                    └─────┬──────┘
                                      ▼ (HTTPS)                          │ (ClusterIP)
                          ┌────────────────────-───┐                     │
                          │ Ingress                │                     │
                          └───────────┬────────────┘                     │
                                      ▼                                  ▼
              ╔══════════════════════════════════════════════════════====════════════================╗
              ║ LiteLLM Proxy  (gateway) - routes by model name                                      ║ 
              ║                          - implements per-userkeys, budget, rate-limit, logging      ║
              ║   "qwen" ─┐         "gpt-oss" ─-┐                                                    ║
              ╚═══════════╪═════════════════════╪════════════════════════════════════================╝
                          │                     │
                          │   OpenAI protocol   │
                          ▼                     ▼
              ╔═════════════════════════════════════════════════════════════════==═===╗
              ║ MODEL SERVING via vLLM (one physical GPU, one model active at a time) ║
              ║                                                                       ║
              ║   ┌─────────────────────┐        ┌─────────────────────┐              ║
              ║   │ vLLM: Qwen3.6-27B   │        │ vLLM: gpt-oss-20b   │              ║
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

## Setup the GPU node

> Why single node + K3s at all: this POC validates the **production deployment
> pattern** (GPU scheduling, operator, manifests) on minimal hardware — not just
> "can the model run." The artifact worth producing is the deployment, not just a
> running model.

1. **Install Ubuntu 24.04 LTS**
   *Why:* best NVIDIA driver/CUDA support and the cleanest base. Hetzner ships a
   bare OS, so you install the GPU stack yourself.

2. **Install the NVIDIA driver** (CUDA toolkit on the host is optional — the CUDA
   *runtime* ships inside the containers)
   *Why:* the GPU is unusable without the kernel driver. Containers reuse the
   host driver, so the host needs it even though CUDA itself lives in the images.

3. **Verify `nvidia-smi`**
   *Why:* confirms the host sees the GPU, driver version, and 20 GB VRAM. If this
   fails, stop and fix — everything below depends on it.

4. **Install the NVIDIA Container Toolkit**
   *Why:* this is what lets containers reach the GPU. Installing it *before* K3s
   means K3s auto-detects the `nvidia` container runtime and creates the
   RuntimeClass for you.

5. **Install K3s (single node)** — control-plane + worker on one box
   *Why:* lightweight orchestration; the layer the whole architecture is validated
   against. K3s bundles Traefik (ingress) and local-path (storage), both reused below.

6. **Install the NVIDIA GPU Operator** (`driver.enabled=false`, `toolkit.enabled=false`
   since the host already has them)
   *Why:* advertises `nvidia.com/gpu` to the scheduler via the device plugin, runs
   node-feature-discovery, and ships the **DCGM exporter** for GPU metrics. This is
   what turns "a GPU in a box" into "a GPU that pods can request."

7. **Create the model-weights PVC** (K3s `local-path`, on NVMe)
   *Why:* persist weights so pod restarts don't re-download ~17 GB.

8. **Deploy vLLM** serving Qwen3.6-27B, requesting `nvidia.com/gpu: 1`, with
   `--gpu-memory-utilization` tuned (and later `--enable-sleep-mode`)
   *Why:* the model server. OpenAI-compatible API, continuous batching for
   multi-user concurrency, and the `/metrics` that answer the concurrency question.

9. **Deploy LiteLLM** (gateway)
   *Why:* single front door — model-name routing, per-user keys, rate-limit,
   logging, and the Anthropic↔OpenAI translation that Claude Code needs. vLLM is
   never hit directly; only LiteLLM talks to it.

10. **Configure Traefik Ingress + TLS** (cert-manager)
    *Why:* one secured HTTPS endpoint for the dev-laptop tools. In-cluster agents
    skip the Ingress and use the ClusterIP.

11. **Deploy observability** — Prometheus + Grafana scraping DCGM + vLLM `/metrics`
    (+ OTel for traces if wanted)
    *Why:* this is the instrument of the POC — GPU utilization, KV-cache pressure,
    preemptions, p95 latency. Without it you can't prove the concurrency ceiling.

12. **Wire up the consumers**
    - kagent: `ModelConfig` with `provider: OpenAI`, `openAI.baseUrl` → LiteLLM
    - kubectl-ai / k8sgpt: OpenAI base URL → LiteLLM
    - Claude Code: `ANTHROPIC_BASE_URL` → LiteLLM's Anthropic endpoint
    *Why:* the actual workload under test.

13. **(Later) Second model + sleep-mode switching**
    *Why:* add gpt-oss-20b, enable Level-1 sleep (weights parked in your 64 GB RAM),
    front with the switch controller — multi-model on one GPU without 2× VRAM.
