#!/usr/bin/env bash
# ④ 앱 배포: namespace → RDS CA 번들(ConfigMap) → overlays/eks 적용 → 롤아웃 대기 → ALB 주소
#   비밀 값은 Secrets Manager → CSI가 K8s Secret으로 동기화 (scripts/k8s/secrets.sh는 ④에서 쓰지 않음)
#   overlays/eks의 자리표시자(ECR_REGISTRY · PROXY_ENDPOINT · RDS_ENDPOINT · *_SECRET_ARN)는 적용할 때만 실제 값으로 바꾼다
#   (저장소에 계정 ID · 주소를 남기지 않음). RDS · Proxy · 비밀은 scripts/eks/rds.sh가 먼저 만들어 둬야 함
# 사용: scripts/eks/deploy.sh          (적용)
#       scripts/eks/deploy.sh diff     (적용하지 않고 kubectl diff — 서버 dry-run 비교)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/eks/env.sh
REG=$(registry); PROXY=$(proxy_endpoint); RDS=$(db_endpoint); ADMIN_ARN=$(admin_secret_arn); APP_ARN=$(app_secret_arn)
for v in PROXY RDS ADMIN_ARN APP_ARN; do
  [ -n "${!v}" ] && [ "${!v}" != None ] || { echo "$v 없음 → scripts/eks/rds.sh 먼저"; exit 1; }; done
render() { kubectl kustomize k8s/overlays/eks | sed -e "s#ECR_REGISTRY#$REG#g" -e "s#PROXY_ENDPOINT#$PROXY#g" \
  -e "s#RDS_ENDPOINT#$RDS#g" -e "s#ADMIN_SECRET_ARN#$ADMIN_ARN#g" -e "s#APP_SECRET_ARN#$APP_ARN#g"; }

if [ "${1:-}" = diff ]; then
  render | k diff -f - 2>&1 | mask; echo "종료 코드: ${PIPESTATUS[1]} (0 = 차이 없음, 1 = 차이 있음)"; exit 0
fi

k apply -f k8s/base/namespace.yaml
# migrate → RDS 직접 접속의 TLS 검증용 공개 CA 번들 (AWS 신뢰 저장소에서 받음)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsS "$RDS_CA_URL" -o "$TMP/bundle.pem"
k -n booklog create configmap rds-ca --from-file=bundle.pem="$TMP/bundle.pem" --dry-run=client -o yaml | k apply -f -
render | k apply -f - | mask
k -n booklog rollout status deploy/was deploy/web --timeout=10m
k -n booklog get pods -o wide
echo "== ALB 주소 (만들어지는 데 몇 분 걸림)"
for i in $(seq 1 40); do
  ADDR=$(k -n booklog get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ADDR" ] && break; sleep 15
done
echo "${ADDR:-아직 없음 — k -n booklog describe ingress web 확인}"
if [ -n "${ADDR:-}" ]; then echo "시나리오: scripts/scenario.sh http://$ADDR write"; fi
