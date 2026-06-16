# Bootstrap

Bootstrap the GPU node running Ubuntu 24.04.

> Why single node + K3s at all:
> this POC validates the **production deployment pattern** (GPU scheduling, operator, manifests) on minimal hardware,
> not just "can the model run."
> The artifact worth producing is the deployment, not just a running model.

1. **Install Ubuntu 24.04 LTS**
  *Why:* best NVIDIA driver/CUDA support and the cleanest base.
  Hetzner ships a bare OS, so you install the GPU stack yourself.

```sh
# Update packages
apt update
apt upgrade
apt full-upgrade
apt autoremove
```

2. **Install the NVIDIA driver**
  *Why:* the GPU is unusable without the kernel driver.
  Containers reuse the host driver, so the host needs it even though CUDA itself lives in the images.
  Skip installing the CUDA toolkit on the host: the CUDA *runtime* ships inside the vLLM container.

```sh
# https://ubuntu.com/blog/deploying-open-language-models-on-ubuntu
apt install -y ubuntu-drivers-common
# list available NVIDIA GPU drivers
ubuntu-drivers list --gpgpu
# inspect the 'recommended' line
ubuntu-drivers devices
# installs it; pulls headers + DKMS as deps
# installs nvidia-driver-595-open
ubuntu-drivers install
reboot
```

3. **Verify `nvidia-smi`**
   *Why:* confirms the host sees the GPU, driver version, and 20 GB VRAM.

```sh
nvidia-smi
# Mon Jun 15 14:33:01 2026
# +-----------------------------------------------------------------------------------------+
# | NVIDIA-SMI 595.71.05              Driver Version: 595.71.05      CUDA Version: 13.2     |
# +-----------------------------------------+------------------------+----------------------+
# | GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
# | Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
# |                                         |                        |               MIG M. |
# |=========================================+========================+======================|
# |   0  NVIDIA RTX 4000 SFF Ada ...    Off |   00000000:01:00.0 Off |                  Off |
# | 34%   57C    P8              8W /   70W |       2MiB /  20475MiB |      0%      Default |
# |                                         |                        |                  N/A |
# +-----------------------------------------+------------------------+----------------------+

# +-----------------------------------------------------------------------------------------+
# | Processes:                                                                              |
# |  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
# |        ID   ID                                                               Usage      |
# |=========================================================================================|
# |  No running processes found                                                             |
# +-----------------------------------------------------------------------------------------+

# TODO?
# Persistence mode is Off.
# On a GPU server it's good practice to enable it so the driver stays initialized between processes
# (nvidia-smi -pm 1, or better, enable the nvidia-persistenced service).
# Minor latency/robustness win; not required since something will always hold the GPU once vLLM runs.

# ECC shows Off. Fine for the POC, and it gives you slightly more usable VRAM/bandwidth.
# Error-Correcting Code memory adds redundant check bits to VRAM so the GPU detects and corrects bit-flips in real time:
# single-bit errors corrected transparently, double-bit errors detected and flagged.
# Without ECC, a flipped bit silently corrupts whatever sits in that cell: model weights, activations, or KV cache.
# VRAM capacity: ECC reserves memory for the check bits, roughly ~6% on NVIDIA GDDR. On your 20 GB card that's ~1.2 GB gone => don't do for POC.
# # Current + Pending mode, error counters
# nvidia-smi -q | grep -i -A3 ecc
# # enable (then reboot / GPU reset)
# nvidia-smi -e 1
# # disable (then reboot)
# nvidia-smi -e 0

nvidia-detector
# nvidia-driver-595
```

4. **Install the NVIDIA Container Toolkit**
  *Why:* this is what lets containers reach the GPU.
  Installing it *before* K3s means K3s auto-detects the `nvidia` container runtime and creates the RuntimeClass for you.

```sh
# https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
apt update && apt install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg2
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update
export NVIDIA_CONTAINER_TOOLKIT_VERSION=1.19.1-1
  apt install -y \
      nvidia-container-toolkit=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
      nvidia-container-toolkit-base=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
      libnvidia-container-tools=${NVIDIA_CONTAINER_TOOLKIT_VERSION} \
      libnvidia-container1=${NVIDIA_CONTAINER_TOOLKIT_VERSION}
# Configuring containerd (for Kubernetes)
# Don't do: K3s runs its own embedded containerd with its own config at /var/lib/rancher/k3s/agent/etc/containerd/, and when you install it after the toolkit it auto-detects the NVIDIA runtime and writes that config itself (plus creates the nvidia RuntimeClass in recent versions).
# nvidia-ctk runtime configure --runtime=containerd
# systemctl restart containerd

nvidia-ctk --version
nvidia-container-cli info
```

5. **Install K3s (single node)**
  *Why:* lightweight orchestration; the layer the whole architecture is validated against.
  K3s bundles Traefik (ingress) and local-path (storage).

```sh
# https://docs.k3s.io/quick-start
# After running this installation:
# The K3s service will be configured to automatically restart after node reboots or if the process crashes or is killed
# Additional utilities will be installed, including kubectl, crictl, ctr, k3s-killall.sh, and k3s-uninstall.sh
# A kubeconfig file will be written to /etc/rancher/k3s/k3s.yaml and the kubectl installed by K3s will automatically use it
# A single-node server installation is a fully-functional Kubernetes cluster, including all the datastore, control-plane, kubelet, and container runtime components necessary to host workload pods. It is not necessary to add additional server or agents nodes, but you may want to do so to add additional capacity or redundancy to your cluster.
curl -sfL https://get.k3s.io | sh -
crictl ps -a
# add to ~/.bashrc to persist
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
# echo "" >> ~/.bashrc
# echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
# echo "source <(kubectl completion bash)" >> ~/.bashrc
# echo "alias k=\"kubectl\"" >> ~/.bashrc
# should go Ready in a few seconds
kubectl get nodes
# Check if `nvidia` runtimeclass exists
kubectl get runtimeclass
# Check the generated containerd config if it references the nvidia runtime
grep -A6 nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml

# Run end-to-end GPU test to see if it gets the GPU
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvidia/cuda:12.6.2-base-ubuntu24.04
    command: ["nvidia-smi"]
    env:
    - name: NVIDIA_VISIBLE_DEVICES
      value: all
    - name: NVIDIA_DRIVER_CAPABILITIES
      value: all
EOF
# should print the same nvidia-smi table you saw on the host
kubectl logs gpu-smoke
kubectl delete pod gpu-smoke
```

6. **Configure firewall**
  *Why:* TODO

```sh
# https://docs.k3s.io/installation/requirements?os=debian
kubectl get -n kube-system svc traefik
# NAME      TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                      AGE
# traefik   LoadBalancer   10.43.219.116   <node-ip>   80:31065/TCP,443:30680/TCP   15m
ss -tulnp | grep -E ':(6443|10250|8472)'
# udp   UNCONN 0      0            0.0.0.0:8472       0.0.0.0:*
# tcp   LISTEN 0      4096               *:10250            *:*    users:(("k3s-server",pid=3435,fd=253))
# tcp   LISTEN 0      4096               *:6443             *:*    users:(("k3s-server",pid=3435,fd=12))
# TCP 6443 — the Kubernetes API server. The control plane of your cluster. You don't want the open internet able to reach it (auth brute-forcing, CVE exposure).
# UDP 8472 — Flannel VXLAN, the pod overlay network. K3s's own docs flag this as the dangerous one: an open VXLAN port lets anyone inject traffic directly onto your internal pod network.
# TCP 10250 — the kubelet API. Historically abused for container exec / RCE when reachable.
#
# On a single node none of these need to face the outside at all — there are no other nodes to talk to them, and kubectl reaches the API over 127.0.0.1:6443.
# 1. allow SSH FIRST — before anything else (use your real SSH port; 22 if default)
ufw allow 22/tcp
# 2. CRITICAL: let pod traffic route. ufw sets FORWARD=DROP by default,
#    which breaks pod networking and image pulls if you skip this.
ufw default allow routed
# 3. deny inbound from the internet, allow outbound
ufw default deny incoming
ufw default allow outgoing
# 4. keep in-cluster traffic working (pods + services)
ufw allow from 10.42.0.0/16
ufw allow from 10.43.0.0/16
# 5. enable
ufw enable
# TODO So configure firewallat the edge (Hetzner Robot firewall for dedicated servers):
# * Default-deny inbound.
# * Allow SSH (your port) — ideally from your IP/VPN, not the whole internet.
# * Allow ICMP, and the return-traffic rule (the Robot firewall is stateless, so you allow inbound TCP with the ACK flag set for established connections — Hetzner's default template handles this).
# * Add 443/tcp later for exposing Traefik.
# rules + the default incoming/outgoing/ROUTED policies
ufw status verbose
# numbered list (use the numbers to delete a specific rule)
ufw status numbered

# Test
# all still Running
kubectl get pods -A
# pod networking + DNS OK
kubectl run dnstest --rm -it --image=busybox --restart=Never -- nslookup kubernetes.default
kubectl run dnstest --rm -it --image=busybox --restart=Never -- nslookup kubernetes.default.svc.cluster.local

nc -zv -w5 <node-ip> 22 80 443 6443 10250
nc -zvu -w5 <node-ip> 8472
# Check also that IPv6 is also blocked
# nc -zv -w5 -6 <node-ip6> 6443
nc -zv -w5 <node-ip> 6443
# python3 -c "import socket; s=socket.socket(socket.AF_INET6); s.settimeout(5); print('open' if s.connect_ex(('<node-ip6>',6443))==0 else 'blocked')"
```

7. **Install the NVIDIA GPU Operator**
  *Why:* advertises `nvidia.com/gpu` to the scheduler via the device plugin,
  runs node-feature-discovery, and ships the **DCGM exporter** for GPU metrics.
  This is what turns "a GPU in a box" into "a GPU that pods can request."

```sh
# Install Helm first
# https://helm.sh/docs/intro/install/#from-apt-debianubuntu
HELM_BUILDKITE_APT_KEY_ID="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
apt install curl gpg apt-transport-https --yes
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey > "${TMPDIR:-/tmp}/helm.gpg"
if [ "$(gpg --show-keys --with-colons "${TMPDIR:-/tmp}/helm.gpg" | awk -F: '$1 == "fpr" {print $10}' | head -n 1)" != "${HELM_BUILDKITE_APT_KEY_ID}" ]; then echo "ERROR: Unexpected Helm APT key ID: potential key compromise"; exit 1; fi
cat "${TMPDIR:-/tmp}/helm.gpg" | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | tee /etc/apt/sources.list.d/helm-stable-debian.list
apt update
apt install helm

# Install the NVIDIA GPU Operator (make the GPU schedulable)
# https://github.com/nvidia/gpu-operator
# https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html
# Returns empty now
kubectl describe nodes | grep nvidia.com/gpu
# Install
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm install gpu-operator -n gpu-operator --create-namespace \
  nvidia/gpu-operator --version=v26.3.2 \
  -f deploy/gpu-operator/config.yaml

kubectl get pods -n gpu-operator
kubectl describe node | grep nvidia.com/gpu
# Verification
# https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#verification-running-sample-gpu-applications
kubectl apply -f deploy/gpu-operator/cuda-vectoradd.yaml
kubectl logs pod/cuda-vectoradd
# [Vector addition of 50000 elements]
# Copy input data from the host memory to the CUDA device
# CUDA kernel launch with 196 blocks of 256 threads
# Copy output data from the CUDA device to the host memory
# Test PASSED
# Done
kubectl delete -f cuda-vectoradd.yaml
```

8. **Setup fluxcd**
   *Why:* TODO

```sh
# https://fluxcd.io/flux/installation/
curl -s https://fluxcd.io/install.sh | bash
# echo "source <(flux completion bash)" >> ~/.bashrc

# https://fluxcd.io/flux/get-started/
# https://fluxcd.io/flux/installation/bootstrap/github/#github-pat
# Validate the cluster
flux check --pre
flux version
# Install flux on the cluster
export GITHUB_USER=<your-username>
export GITHUB_TOKEN=<your-PAT>
# This installs the controllers, creates clusters/llm-platform/flux-system/, and commits it to your repo.
flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=llm-platform \
  --branch=main \
  --path=./clusters/llm-platform \
  --personal
kubectl get pods -n flux-system
# git pull

# Encrypting/Decrypting secrets using age
# https://fluxcd.io/flux/guides/mozilla-sops/#encrypting-secrets-using-age
age-keygen -o flux.agekey
cat flux.agekey |
  kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
kubectl get secret -n flux-system sops-age -o yaml | yq '.data["age.agekey"]'

# Verify
flux get kustomizations
flux get helmreleases -A
# operator still healthy after adoption
kubectl get pods -n gpu-operator
```

<!--8. **Create the model-weights PVC** (K3s `local-path`, on NVMe)
  *Why:* persist weights so pod restarts don't re-download ~17 GB.

```sh

```

9. **Deploy vLLM** serving Qwen3.6-27B, requesting `nvidia.com/gpu: 1`, with
  `--gpu-memory-utilization` tuned (and later `--enable-sleep-mode`)
  *Why:* the model server. OpenAI-compatible API, continuous batching for
  multi-user concurrency, and the `/metrics` that answer the concurrency question.

```sh

```

10. **Deploy LiteLLM** (gateway)
  *Why:* single front door — model-name routing, per-user keys, rate-limit,
  logging, and the Anthropic↔OpenAI translation that Claude Code needs. vLLM is
  never hit directly; only LiteLLM talks to it.

```sh

```

11. **Configure Traefik Ingress + TLS** (cert-manager)
    *Why:* one secured HTTPS endpoint for the dev-laptop tools. In-cluster agents
    skip the Ingress and use the ClusterIP.

```sh

```

12. **Deploy observability** — Prometheus + Grafana scraping DCGM + vLLM `/metrics`
    (+ OTel for traces if wanted)
    *Why:* this is the instrument of the POC — GPU utilization, KV-cache pressure,
    preemptions, p95 latency. Without it you can't prove the concurrency ceiling.

```sh

```

13. **Wire up the consumers**
    - kagent: `ModelConfig` with `provider: OpenAI`, `openAI.baseUrl` → LiteLLM
    - kubectl-ai / k8sgpt: OpenAI base URL → LiteLLM
    - Claude Code: `ANTHROPIC_BASE_URL` → LiteLLM's Anthropic endpoint
    *Why:* the actual workload under test.

```sh

```

14. **(Later) Second model + sleep-mode switching**
    *Why:* add gpt-oss-20b, enable Level-1 sleep (weights parked in your 64 GB RAM),
    front with the switch controller — multi-model on one GPU without 2× VRAM.

```sh

```-->
