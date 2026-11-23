#!/usr/bin/env bash
# ③ 노드 공통 준비 (cp · worker1 · worker2 모두). 노드 안에서 root 권한으로 실행한다.
#   WSL에서: for h in cp worker1 worker2; do ssh $h 'sudo bash -s' < scripts/k8s/node-prep.sh; done
# 근거: kubeadm 설치 문서(Red Hat 계열), containerd · Calico 문서. 여러 번 실행해도 결과가 같다.
set -euo pipefail
K8S_MINOR=v1.36
K8S_VERSION=1.36.6

echo "[$(hostname)] 1) SELinux Permissive (kubeadm 문서: 컨테이너가 호스트 파일시스템에 접근하도록)"
setenforce 0 || true
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo "[$(hostname)] 2) swap 끄기 확인 (kubelet 기본: swap이 있으면 실패)"
swapoff -a; sed -i '/\sswap\s/ s/^/#/' /etc/fstab

echo "[$(hostname)] 3) 커널 모듈 · sysctl (컨테이너 네트워크 · 패킷 포워딩)"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay; modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "[$(hostname)] 4) NetworkManager가 Calico 인터페이스를 건드리지 않게 (Calico 문서)"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/calico.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF
systemctl reload NetworkManager || true

echo "[$(hostname)] 5) containerd (Docker 저장소의 containerd.io), SystemdCgroup = true"
dnf -y -q install dnf-plugins-core iproute-tc
dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null
dnf -y -q install containerd.io
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || { echo "SystemdCgroup 설정 실패"; exit 1; }
systemctl enable --now containerd >/dev/null 2>&1; systemctl restart containerd

echo "[$(hostname)] 6) kubeadm · kubelet · kubectl $K8S_VERSION (pkgs.k8s.io $K8S_MINOR, exclude로 자동 업데이트 막음)"
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_MINOR/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
dnf -y -q install kubelet-$K8S_VERSION kubeadm-$K8S_VERSION kubectl-$K8S_VERSION cri-tools --disableexcludes=kubernetes
systemctl enable kubelet >/dev/null 2>&1

echo "[$(hostname)] 확인"
echo "  selinux=$(getenforce) swap=$(swapon --show | wc -l) ip_forward=$(sysctl -n net.ipv4.ip_forward) bridge-nf=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo "  containerd=$(containerd --version | awk '{print $3}') $(grep -c 'SystemdCgroup = true' /etc/containerd/config.toml)곳 SystemdCgroup=true, 상태=$(systemctl is-active containerd)"
echo "  kubeadm=$(kubeadm version -o short) kubelet=$(kubelet --version | awk '{print $2}') kubectl=$(kubectl version --client -o yaml | awk '/gitVersion/{print $2}')"
