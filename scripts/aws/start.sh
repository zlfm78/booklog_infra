#!/usr/bin/env bash
# EC2 3대 시작 → 공인 IP가 바뀌므로 status.sh로 ssh 설정 갱신
set -euo pipefail
source "$(dirname "$0")/env.sh"
IDS=$(instances stopped); [ -n "$IDS" ] || { echo "정지된 인스턴스 없음"; exit 0; }
aws ec2 start-instances --instance-ids $IDS --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
aws ec2 wait instance-running --instance-ids $IDS
"$(dirname "$0")/status.sh"
