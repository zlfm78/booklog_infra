#!/usr/bin/env bash
# Calico 공식 매니페스트(v3.33.1, 기본: IP-in-IP Always + BGP)를 VXLAN 전용으로 바꿔 calico.yaml을 만든다
#   입력: k8s/cluster/calico/calico-v3.33.1.upstream.yaml (원본 그대로 보관)
#   출력: k8s/cluster/calico/calico.yaml (kubectl apply 대상) + 바뀐 부분 diff 출력
# 이유: 보안 그룹이 노드 사이 UDP 4789만 허용(IP-in-IP 프로토콜 4, BGP TCP 179는 막음) → 설계.md 3.2
set -euo pipefail
D="$(cd "$(dirname "$0")/../.." && pwd)/k8s/cluster/calico"
IN=$D/calico-v3.33.1.upstream.yaml; OUT=$D/calico.yaml
sed -E \
  -e 's/^(  calico_backend: )"bird"/\1"vxlan"/' \
  -e '/name: CALICO_IPV4POOL_IPIP/{n;s/value: "Always"/value: "Never"/}' \
  -e '/name: CALICO_IPV4POOL_VXLAN/{n;s/value: "Never"/value: "Always"/}' \
  -e 's/^(\s+)# (- name: CALICO_IPV4POOL_CIDR)/\1\2/' \
  -e '/- name: CALICO_IPV4POOL_CIDR/{n;s/^(\s+)#   (value: "192\.168\.0\.0\/16")/\1  \2/}' \
  -e '/^\s+- --bird-(live|ready)$/d' \
  "$IN" > "$OUT"
diff "$IN" "$OUT" || true
