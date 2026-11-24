#!/usr/bin/env bash
# .env 값으로 Secret 3개를 클러스터에 직접 만든다/갱신한다 (값을 파일 · 화면 · 저장소에 남기지 않음)
#   booklog-db-admin: DB_ADMIN_USER, DB_ADMIN_PASSWORD   (db 초기화 · migrate)
#   booklog-app:      DB_USER, DB_PASSWORD, JWT_SECRET    (was)
#   booklog-demo:     DEMO_PASSWORD                       (migrate의 시드)
# 사용: scripts/k8s/secrets.sh   (네임스페이스 booklog가 있어야 함)
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; . ./.env; set +a
for k in DB_ADMIN_USER DB_ADMIN_PASSWORD DB_USER DB_PASSWORD JWT_SECRET DEMO_PASSWORD; do
  [ -n "${!k:-}" ] || { echo ".env에 $k 값이 없음"; exit 1; }
done
# --dry-run=client -o yaml | kubectl apply: 없으면 만들고 있으면 갱신. 값은 표준 입출력으로만 오가고 출력하지 않음
mk() { kubectl create secret generic "$1" -n booklog "${@:2}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "secret/$1 적용 (키: $(kubectl get secret "$1" -n booklog -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}'))"; }
mk booklog-db-admin --from-literal=DB_ADMIN_USER="$DB_ADMIN_USER" --from-literal=DB_ADMIN_PASSWORD="$DB_ADMIN_PASSWORD"
mk booklog-app --from-literal=DB_USER="$DB_USER" --from-literal=DB_PASSWORD="$DB_PASSWORD" --from-literal=JWT_SECRET="$JWT_SECRET"
mk booklog-demo --from-literal=DEMO_PASSWORD="$DEMO_PASSWORD"
