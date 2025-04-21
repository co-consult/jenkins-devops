#!/bin/bash

# Exit on any error
set -e

# Ensure script is run with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run with sudo (e.g., 'sudo bash cluster.sh')"
    exit 1
fi

# Create log file and set permissions for ubuntu user
LOG_FILE="/var/log/k8s-setup.log"
touch "$LOG_FILE"
chown ubuntu:ubuntu "$LOG_FILE"
chmod 664 "$LOG_FILE"

# Redirect output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Ensure ubuntu user has sudo privileges
if ! groups ubuntu | grep -q '\bsudo\b'; then
    usermod -aG sudo ubuntu
    echo "Added ubuntu to sudo group"
fi
# Enable passwordless sudo for ubuntu
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu
chmod 440 /etc/sudoers.d/90-ubuntu
echo "Configured passwordless sudo for ubuntu"

# Check if OS is Ubuntu 22.04
if [ "$(lsb_release -is)" != "Ubuntu" ] || [ "$(lsb_release -rs)" != "22.04" ]; then
    echo "Error: OS should be Ubuntu 22.04"
    exit 1
fi

# Variables
IP_ADDRESS="10.0.0.4"
if [ "$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)" != "$IP_ADDRESS" ]; then
    echo "Error: IP_ADDRESS does not match eth0 IP"
    exit 1
fi

# Configure network (use DHCP for Azure)
cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: yes
EOF
# Set secure permissions for netplan config
chmod 600 /etc/netplan/01-netcfg.yaml
netplan apply

# Update packages
apt update

# Disable swap
swapoff -a
sed -i '/\bswap\b/s/^/#/' /etc/fstab
if swapon --show | grep -q .; then
    echo "Error: Swap is still enabled"
    exit 1
fi

# Set hostname
hostnamectl set-hostname master
echo "${IP_ADDRESS} master" >> /etc/hosts

# Configure kernel modules for containerd
cat > /etc/modules-load.d/containerd.conf << EOF
overlay
br_netfilter
EOF

# Configure sysctl params for Kubernetes
cat > /etc/sysctl.d/99-kubernetes-cri.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system

# Install prerequisites
apt install -y apt-transport-https ca-certificates curl

# Add Docker repository
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker-apt-keyring.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-apt-keyring.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key -o /etc/apt/keyrings/kubernetes-apt-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

# Update and install packages
apt update
KUBE_VERSION="1.29.2-1.1"
apt install -y containerd.io kubelet=${KUBE_VERSION} kubeadm=${KUBE_VERSION} kubectl=${KUBE_VERSION}

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# Set pause image to 3.9
sed -i 's|sandbox_image = "registry.k8s.io/pause:3.8"|sandbox_image = "registry.k8s.io/pause:3.9"|' /etc/containerd/config.toml
if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
    echo "Error: Failed to enable SystemdCgroup in containerd config"
    exit 1
fi
if ! grep -q "registry.k8s.io/pause:3.9" /etc/containerd/config.toml; then
    echo "Error: Failed to set pause image to 3.9"
    exit 1
fi

# Enable and start services
systemctl daemon-reload
systemctl enable containerd kubelet
systemctl restart containerd

# Load kernel module
modprobe br_netfilter

# Initialize Kubernetes cluster (single-node)
kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint="${IP_ADDRESS}:6443" --ignore-preflight-errors=NumCPU

# Wait for initialization
sleep 30

# Set up kubeconfig for ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config


# Remove taint for single-node cluster
su - ubuntu -c "kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule- || true"

# Install Calico network plugin
su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml" || {
    echo "Error: Failed to apply Calico"
    exit 1
}
su - ubuntu -c "kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=120s" || {
    echo "Error: Calico pods not ready"
    exit 1
}

# Install MetalLB
su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-frr.yaml" || {
    echo "Error: Failed to apply MetalLB"
    exit 1
}
su - ubuntu -c "kubectl wait --for=condition=ready pod -l app=metallb -n metallb-system --timeout=120s" || {
    echo "Error: MetalLB pods not ready"
    exit 1
}

# Create and apply MetalLB configuration
cat > /home/ubuntu/metallb-config.yaml << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 10.0.0.100-10.0.0.150
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF
chown ubuntu:ubuntu /home/ubuntu/metallb-config.yaml
su - ubuntu -c "kubectl apply -f /home/ubuntu/metallb-config.yaml" || {
    echo "Error: Failed to apply MetalLB config"
    exit 1
}

# Verify cluster
su - ubuntu -c "kubectl get nodes"
su - ubuntu -c "kubectl get pods -A"

# Reboot system
echo "Setup complete. Rebooting in 10 seconds (Ctrl+C to cancel)..."
sleep 10
reboot