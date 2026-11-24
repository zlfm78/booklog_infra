#!/usr/bin/env bash
# ④ 앱 배포: namespace → Secret(.env 값, scripts/k8s/secrets.sh) → overlays/eks 적용 → 롤아웃 대기 → ALB 주소
#   overlays/eks의 이미지 주소는 ECR_REGISTRY 자리표시자다 (저장소에 계정 ID를 남기지 않음).
#   적용할 때만 실제 레지스트리 주소로 바꾼다.
# 사용: scripts/eks/deploy.sh          (적용)
#       scripts/eks/deploy.sh diff     (적용하지 않고 kubectl diff — 서버 dry-run 비교)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/eks/env.sh
REG=$(registry)
render() { kubectl kustomize k8s/overlays/eks | sed "s#ECR_REGISTRY#$REG#g"; }

if [ "${1:-}" = diff ]; then
  render | k diff -f - 2>&1 | mask; echo "종료 코드: ${PIPESTATUS[1]} (0 = 차이 없음, 1 = 차이 있음)"; exit 0
fi

k apply -f k8s/base/namespace.yaml
KUBECONFIG="$KUBECONFIG_EKS" scripts/k8s/secrets.sh
render | k apply -f - | mask
k -n booklog rollout status statefulset/db deploy/was deploy/web --timeout=10m
k -n booklog get pods -o wide
echo "== ALB 주소 (만들어지는 데 몇 분 걸림)"
for i in $(seq 1 40); do
  ADDR=$(k -n booklog get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ADDR" ] && break; sleep 15
done
echo "${ADDR:-아직 없음 — k -n booklog describe ingress web 확인}"
if [ -n "${ADDR:-}" ]; then echo "시나리오: scripts/scenario.sh http://$ADDR write"; fi
