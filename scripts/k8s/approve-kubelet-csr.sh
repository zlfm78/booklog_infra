#!/usr/bin/env bash
# kubelet serving 인증서 요청(CSR)을 확인하고 승인 (serverTLSBootstrap: true이면 kubeadm이 자동 승인하지 않음)
# 승인 조건: signer = kubernetes.io/kubelet-serving, 요청자 = system:node:<우리 노드>, 상태 Pending,
#            인증서의 CN = system:node:<같은 노드>, IP SAN = 그 노드의 고정 사설 IP만
# 조건이 하나라도 다르면 승인하지 않고 이유를 출력한다 (가짜 노드에 인증서를 내주지 않도록)
set -euo pipefail
declare -A NODE_IP=([cp]=10.0.1.10 [worker1]=10.0.1.11 [worker2]=10.0.1.12)

for csr in $(kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{"\n"}{end}'); do
  status=$(kubectl get csr "$csr" -o jsonpath='{.status.conditions[*].type}')
  [ -z "$status" ] || continue                                   # 이미 Approved/Denied
  user=$(kubectl get csr "$csr" -o jsonpath='{.spec.username}')
  node=${user#system:node:}
  if [ "$user" = "$node" ] || [ -z "${NODE_IP[$node]:-}" ]; then echo "$csr 건너뜀: 요청자 $user 는 우리 노드가 아님"; continue; fi
  req=$(kubectl get csr "$csr" -o jsonpath='{.spec.request}' | base64 -d)
  cn=$(openssl req -noout -subject <<<"$req" | sed -E 's/.*CN ?= ?([^,/]+).*/\1/')
  ips=$(openssl req -noout -text <<<"$req" | grep -oE 'IP Address:[0-9.]+' | cut -d: -f2 | sort -u | tr '\n' ' ' | sed 's/ $//')
  if [ "$cn" != "system:node:$node" ] || [ "$ips" != "${NODE_IP[$node]}" ]; then
    echo "$csr 건너뜀: CN=$cn IP=[$ips] (기대: system:node:$node, ${NODE_IP[$node]})"; continue
  fi
  echo "$csr 확인: 요청자=$user CN=$cn IP=$ips → 승인"
  kubectl certificate approve "$csr" >/dev/null
done
