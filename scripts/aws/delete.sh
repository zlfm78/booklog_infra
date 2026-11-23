#!/usr/bin/env bash
# ③ 자원 전부 삭제 (Project=booklog 태그만). 의존 관계 역순:
#   EC2 종료(루트 EBS는 DeleteOnTermination) → 보안 그룹 → IGW 분리 · 삭제 → 서브넷 → VPC(기본 라우팅 테이블 함께) → 키 페어
# 사용: scripts/aws/delete.sh yes   (인자 yes가 없으면 지울 목록만 보여 줌)
set -euo pipefail
source "$(dirname "$0")/env.sh"
VPC=$(vpc_id); IDS=$(instances)
echo "지울 대상: VPC=$VPC 인스턴스=[${IDS:-없음}] 키 페어=$KEY_NAME"
[ "${1:-}" = yes ] || { echo "→ 실제로 지우려면: $0 yes"; exit 0; }

if [ -n "$IDS" ]; then
  aws ec2 terminate-instances --instance-ids $IDS --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text
  aws ec2 wait instance-terminated --instance-ids $IDS
fi
if [ "$VPC" != "None" ]; then
  for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=tag:Project,Values=$PROJECT --query 'SecurityGroups[].GroupId' --output text); do
    aws ec2 delete-security-group --group-id $sg && echo "SG $sg 삭제"; done
  for igw in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC
    aws ec2 delete-internet-gateway --internet-gateway-id $igw && echo "IGW $igw 삭제"; done
  for sn in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id $sn && echo "서브넷 $sn 삭제"; done
  aws ec2 delete-vpc --vpc-id $VPC && echo "VPC $VPC 삭제"
fi
aws ec2 delete-key-pair --key-name $KEY_NAME >/dev/null && echo "키 페어 $KEY_NAME 삭제"

echo "== 남은 자원 확인 (모두 비어 있어야 함)"
echo "인스턴스: $(aws ec2 describe-instances --filters Name=tag:Project,Values=$PROJECT Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "볼륨:     $(aws ec2 describe-volumes --filters Name=tag:Project,Values=$PROJECT --query 'Volumes[].VolumeId' --output text)"
echo "VPC:      $(aws ec2 describe-vpcs --filters Name=tag:Project,Values=$PROJECT --query 'Vpcs[].VpcId' --output text)"
echo "EIP:      $(aws ec2 describe-addresses --filters Name=tag:Project,Values=$PROJECT --query 'Addresses[].PublicIp' --output text)"
