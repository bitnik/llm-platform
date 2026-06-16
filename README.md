# llm-platform

This is a POC for a self-hosted LLM platform on K3s - GPU inference with vLLM behind a LiteLLM gateway, cloud-native agent tooling, GitOps-managed.

## Machine

https://www.hetzner.com/dedicated-rootserver/gex44/

## System Diagram

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

## Bootstrap

See [bootstrap/README.md](bootstrap/README.md) for the full bootstrap guide.

## Deploy

TODO document [deploy](deploy) using fluxcd

## Development

Required: just, age, sops, fluxcd

TODO
