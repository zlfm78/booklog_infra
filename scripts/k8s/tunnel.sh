#!/usr/bin/env bash
# WSL → cp API 서버 SSH 터널 (6443을 인터넷에 열지 않고 kubectl 사용)
#   scripts/k8s/tunnel.sh        터널 열기 (이미 열려 있으면 그대로)
#   scripts/k8s/tunnel.sh stop   터널 닫기
# kubeconfig의 server는 https://127.0.0.1:6443 (API 서버 인증서 SAN에 127.0.0.1 포함)
set -euo pipefail
SOCK=~/.ssh/booklog-tunnel.sock
if [ "${1:-}" = stop ]; then ssh -S "$SOCK" -O exit cp 2>/dev/null && echo "터널 닫음" || echo "열린 터널 없음"; exit 0; fi
if ssh -S "$SOCK" -O check cp 2>/dev/null; then echo "터널 이미 열림"; exit 0; fi
# -f 백그라운드, -N 명령 없음, -M -S 제어 소켓(닫을 때 사용), ExitOnForwardFailure: 포트를 못 열면 실패로 끝냄
ssh -f -N -M -S "$SOCK" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 6443:127.0.0.1:6443 cp
echo "터널 열림: 127.0.0.1:6443 → cp:6443"
