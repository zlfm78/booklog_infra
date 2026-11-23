#!/usr/bin/env bash
# EC2 3대 정지 (인스턴스 요금 중지. EBS 20GiB × 3 · 퍼블릭 IP 없는 상태의 요금은 남음)
set -euo pipefail
source "$(dirname "$0")/env.sh"
IDS=$(instances running); [ -n "$IDS" ] || { echo "실행 중인 인스턴스 없음"; exit 0; }
aws ec2 stop-instances --instance-ids $IDS --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
aws ec2 wait instance-stopped --instance-ids $IDS
"$(dirname "$0")/status.sh"
