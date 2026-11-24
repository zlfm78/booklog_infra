#!/usr/bin/env bash
# ④ 자원 삭제 (Project=booklog-eks · 클러스터 booklog만). 순서가 중요하다:
#   1) Ingress → ALB 삭제 (Auto Mode가 지움)   2) namespace booklog → PVC → EBS 삭제 (reclaimPolicy: Delete)
#   3) NodePool → 앱 노드 종료   4) 클러스터   5) NAT   6) 보안 그룹 · 라우팅 · IGW · 서브넷 · VPC   7) IAM 역할
#   클러스터를 먼저 지우면 ALB · EBS를 지워 줄 컨트롤러가 없어져 남을 수 있음 → 1) 2)를 먼저
# 사용: scripts/eks/delete.sh yes        (ECR은 남김 — 다음 날 클러스터만 다시 만들 때)
#       scripts/eks/delete.sh yes all    (ECR까지 삭제 — 발표 후)
#       인자 yes가 없으면 지울 목록만 보여 줌
set -euo pipefail
source "$(dirname "$0")/env.sh"
VPC=$(vpc_id)
"$(dirname "$0")/status.sh"
[ "${1:-}" = yes ] || { echo "→ 실제로 지우려면: $0 yes   (ECR까지: $0 yes all)"; exit 0; }
waitfor() { # 설명 최대초 조건명령 — 조건 출력이 빌 때까지 기다림
  local t=0; while [ -n "$(eval "$3")" ]; do [ $t -ge $2 ] && { echo "시간 초과: $1"; return 1; }; sleep 15; t=$((t+15)); done; echo "$1 완료 (${t}초)"; }

if aws eks describe-cluster --name $CLUSTER >/dev/null 2>&1 && [ -f "$KUBECONFIG_EKS" ]; then
  echo "== 1) Ingress 삭제 → ALB"
  k delete ingress --all -n booklog --ignore-not-found --wait=true
  [ "$VPC" != "None" ] && waitfor "ALB 삭제" 600 "aws elbv2 describe-load-balancers --query \"LoadBalancers[?VpcId=='$VPC'].LoadBalancerArn\" --output text"
  echo "== 2) namespace booklog 삭제 → PVC → EBS"
  # 지우기 전에 PV가 가리키는 EBS 볼륨 ID를 받아 두고, 그 ID가 사라질 때까지 기다린다
  VOLS=$(k get pv -o jsonpath='{range .items[?(@.spec.claimRef.namespace=="booklog")]}{.spec.csi.volumeHandle}{" "}{end}')
  echo "PV의 EBS 볼륨: ${VOLS:-없음}"
  k delete namespace booklog --ignore-not-found --wait=true
  for v in $VOLS; do
    waitfor "EBS $v 삭제" 600 "aws ec2 describe-volumes --volume-ids $v --query 'Volumes[].VolumeId' --output text 2>/dev/null || true"
  done
  echo "== 3) NodePool 삭제 → 앱 노드 종료"
  k delete nodepool booklog --ignore-not-found --wait=true || true
fi

if aws eks describe-cluster --name $CLUSTER >/dev/null 2>&1; then
  echo "== 4) 클러스터 삭제 (보통 5~10분)"
  aws eks delete-cluster --name $CLUSTER --query 'cluster.status' --output text
  aws eks wait cluster-deleted --name $CLUSTER
fi
rm -f "$KUBECONFIG_EKS"

if [ "$VPC" != "None" ]; then
  IDS=$(aws ec2 describe-instances --include-managed-resources --filters Name=vpc-id,Values=$VPC Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
  [ -n "$IDS" ] && { echo "남은 노드 종료: $IDS"; aws ec2 terminate-instances --instance-ids $IDS >/dev/null; aws ec2 wait instance-terminated --instance-ids $IDS; }
  echo "== 5) NAT 삭제"
  for n in $(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text); do
    aws ec2 delete-nat-gateway --nat-gateway-id $n >/dev/null; aws ec2 wait nat-gateway-deleted --nat-gateway-ids $n; echo "NAT $n 삭제"; done
  echo "== 6) 보안 그룹 · 라우팅 · IGW · 서브넷 · VPC"
  waitfor "ENI 정리" 600 "aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC Name=status,Values=in-use --query 'NetworkInterfaces[].NetworkInterfaceId' --output text"
  for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    aws ec2 delete-security-group --group-id $sg && echo "SG $sg 삭제" || echo "SG $sg 삭제 실패(다시 실행)"; done
  for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC --query 'RouteTables[?!(Associations[?Main])].RouteTableId' --output text); do
    for a in $(aws ec2 describe-route-tables --route-table-ids $rt --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do aws ec2 disassociate-route-table --association-id $a; done
    aws ec2 delete-route-table --route-table-id $rt && echo "라우팅 테이블 $rt 삭제"; done
  for igw in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC; aws ec2 delete-internet-gateway --internet-gateway-id $igw && echo "IGW $igw 삭제"; done
  for sn in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id $sn && echo "서브넷 $sn 삭제"; done
  aws ec2 delete-vpc --vpc-id $VPC && echo "VPC $VPC 삭제"
fi

echo "== 7) IAM 역할"
for r in $CLUSTER_ROLE $NODE_ROLE; do
  aws iam get-role --role-name $r >/dev/null 2>&1 || continue
  for p in $(aws iam list-attached-role-policies --role-name $r --query 'AttachedPolicies[].PolicyArn' --output text); do aws iam detach-role-policy --role-name $r --policy-arn $p; done
  aws iam delete-role --role-name $r && echo "역할 $r 삭제"
done

if [ "${2:-}" = all ]; then
  echo "== 8) ECR 저장소 (이미지 포함)"
  for r in "${ECR_REPOS[@]}"; do aws ecr delete-repository --repository-name $r --force >/dev/null 2>&1 && echo "ECR $r 삭제" || true; done
fi

echo "== 남은 자원 확인 (ECR을 남겼다면 ECR만 있어야 함)"
"$(dirname "$0")/status.sh"
