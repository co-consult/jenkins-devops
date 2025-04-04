#!/bin/bash

# Exit on any error
set -e

# Check if OS is Ubuntu 22.04
if [ "$(lsb_release -is)" != "Ubuntu" ] || [ "$(lsb_release -rs)" != "22.04" ]; then
    echo "Error: OS should be Ubuntu 22.04"
    exit 1
fi

# Variables
IP_ADDRESS=""
GATEWAY=""

# Configure network
cat > /etc/netplan/01-netcfg.yaml << EOF
network:
  version: 2
  ethernets:
    vmbr0:
      dhcp4: no
      addresses:
        - ${IP_ADDRESS}/24
      gateway4: ${GATEWAY}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
EOF

netplan apply

# Update packages
apt update

# Disable swap
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

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
apt install -y apt-transport-https

# Add Docker repository
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker-apt-keyring.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker-apt-keyring.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key -o /etc/apt/keyrings/kubernetes-apt-keyring.asc
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.asc] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" > /etc/apt/sources.list.d/kubernetes.list

# Update and install packages
apt update
apt install -y containerd.io kubelet=1.29.* kubeadm=1.29.* kubectl=1.29.*

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Enable and start services
systemctl daemon-reload
systemctl enable containerd kubelet
systemctl restart containerd

# Load kernel module
modprobe br_netfilter

# Initialize Kubernetes cluster
kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint="${IP_ADDRESS}:6443"

# Wait for initialization
sleep 30

# Set up kubeconfig for ubuntu user
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Install Calico network plugin (as ubuntu user)
su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml"

# Install MetalLB (as ubuntu user)
su - ubuntu -c "kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-frr.yaml"

# Apply MetalLB configuration (as ubuntu user)
su - ubuntu -c "kubectl apply -f /home/ubuntu/metallb-config.yaml"

# Reboot system
reboot