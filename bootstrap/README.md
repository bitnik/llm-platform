# Bootstrap

Commands to bootstrap a GPU node running Ubuntu 24.04 LTS,
following the plan described in the [main README](README.md#setup-the-gpu-node).

```sh
# ssh into the GPU node
apt update
apt upgrade
apt full-upgrade
apt autoremove

# Install the NVIDIA driver
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
nvidia-detector
# nvidia-driver-595

# TODO? Persistence mode is Off. On a GPU server it's good practice to enable it so the driver stays initialized between processes (nvidia-smi -pm 1, or better, enable the nvidia-persistenced service). Minor latency/robustness win; not required since something will always hold the GPU once vLLM runs.

# ECC shows Off. Fine for the POC, and it gives you slightly more usable VRAM/bandwidth.
# Error-Correcting Code memory adds redundant check bits to VRAM so the GPU detects and corrects bit-flips in real time — single-bit errors corrected transparently, double-bit errors detected and flagged.
# Without ECC, a flipped bit silently corrupts whatever sits in that cell — model weights, activations, or KV cache. 
# VRAM capacity: ECC reserves memory for the check bits, roughly ~6% on NVIDIA GDDR. On your 20 GB card that's ~1.2 GB gone => don't do for POC.
# # Current + Pending mode, error counters
# nvidia-smi -q | grep -i -A3 ecc
# # enable (then reboot / GPU reset)
# nvidia-smi -e 1
# # disable (then reboot)
# nvidia-smi -e 0

# Install the NVIDIA Container Toolkit
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

# Install K3s (single node)
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
# expect 'nvidia' to be present
kubectl get runtimeclass

# Configure firewall
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

# end-to-end GPU test
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
    image: nvidia/cuda:12.6.2-base-ubuntu24.04   # or any current cuda *-base tag
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

# Install the NVIDIA GPU Operator (make the GPU schedulable)
# https://github.com/nvidia/gpu-operator
# Returns empty now
kubectl describe node | grep nvidia.com/gpu 
```
