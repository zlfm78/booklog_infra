#!/usr/bin/env bash
# 롤링 업데이트 중 요청이 실패하는지 세는 도구
#   scripts/k8s/traffic.sh start <BASE_URL>   백그라운드로 /api/info를 0.05초마다 호출 (결과는 /tmp/booklog-traffic.log)
#   scripts/k8s/traffic.sh stop               멈추고 요약: 전체 · 실패(200 아님) · 응답 버전이 바뀐 순서
set -u
LOG=/tmp/booklog-traffic.log; PIDF=/tmp/booklog-traffic.pid
case "${1:-}" in
  start)
    : > "$LOG"
    ( while :; do curl -s -o /dev/null --max-time 3 -w '%{http_code} %header{x-app-version}\n' "$2/api/info" >> "$LOG"; sleep 0.05; done ) &
    echo $! > "$PIDF"; echo "트래픽 시작 → $2/api/info" ;;
  stop)
    kill "$(cat "$PIDF")" 2>/dev/null; sleep 0.5
    total=$(wc -l < "$LOG"); fail=$(grep -vc '^200 ' "$LOG")
    echo "전체 요청 $total, 실패(200 아님) $fail"
    [ "$fail" -gt 0 ] && { echo "실패 응답 코드:"; grep -v '^200 ' "$LOG" | awk '{print "  " $1}' | sort | uniq -c; }
    echo "응답 버전 순서 (연속 구간별 요청 수):"
    awk '$1=="200"{v=$2} $1!="200"{v="(실패 " $1 ")"} v!=p{if(p!="")printf "  %s × %d\n",p,n; p=v; n=0} {n++} END{printf "  %s × %d\n",p,n}' "$LOG" ;;
  *) echo "사용: $0 start <BASE_URL> | stop"; exit 2 ;;
esac
