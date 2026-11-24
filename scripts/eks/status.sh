#!/usr/bin/env bash
# ④ 과금 자원 조회 — 작업을 끝낼 때마다, 그리고 발표 후 삭제 뒤 "남은 자원 없음" 증거로 실행
#   Auto Mode 노드는 "관리형 리소스"라 EC2 목록에서 기본으로 숨겨짐 → describe-instances에 --include-managed-resources (2026-11-24 확인)
#   태그 Project=booklog-eks · 클러스터 이름 · VPC로 찾는다 (수업 자원은 조회하지 않음)
set -euo pipefail
source "$(dirname "$0")/env.sh"
VPC=$(vpc_id); [ "$VPC" = "None" ] && VPC=""
show() { printf '%-22s %s\n' "$1" "${2:-없음}"; }

show "EKS 클러스터" "$(aws eks describe-cluster --name $CLUSTER --query 'cluster.[status,version]' --output text 2>/dev/null || true)"
show "VPC" "$VPC"
if [ -n "$VPC" ]; then
  show "EC2 (노드)" "$(aws ec2 describe-instances --include-managed-resources --filters Name=vpc-id,Values=$VPC Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,Placement.AvailabilityZone,State.Name]' --output text | tr '\t\n' ' ;')"
  show "NAT 게이트웨이" "$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC Name=state,Values=pending,available,deleting \
        --query 'NatGateways[].[NatGatewayId,State,AvailabilityMode]' --output text | tr '\t\n' ' ;')"
  show "로드밸런서" "$(aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$VPC'].[LoadBalancerName,Type,State.Code]" --output text | tr '\t\n' ' ;')"
  show "서브넷" "$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'length(Subnets)' --output text)개"
  show "ENI" "$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC --query 'length(NetworkInterfaces)' --output text)개"
fi
# EBS: PVC로 만든 볼륨(EBS CSI가 붙이는 태그) + 이 프로젝트 태그
show "EBS 볼륨" "$(aws ec2 describe-volumes --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name,ebs.csi.eks.amazonaws.com/cluster \
      --query 'Volumes[].[VolumeId,Size,State,Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value]' --output text | tr '\t\n' ' ;')"
show "EIP (Project 태그)" "$(aws ec2 describe-addresses --filters Name=tag:Project,Values=$PROJECT --query 'Addresses[].PublicIp' --output text)"
show "RDS" "$(aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].[DBInstanceStatus,DBInstanceClass,MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]' --output text 2>/dev/null | tr '\t' ' ' || true)"
show "RDS Proxy" "$(aws rds describe-db-proxies --db-proxy-name $DB_ID --query 'DBProxies[0].[Status,DefaultAuthScheme]' --output text 2>/dev/null | tr '\t' ' ' || true)"
show "DB 서브넷 그룹" "$(aws rds describe-db-subnet-groups --db-subnet-group-name $DB_ID --query 'DBSubnetGroups[0].DBSubnetGroupName' --output text 2>/dev/null || true)"
show "Secrets Manager" "$(aws secretsmanager list-secrets --filters Key=name,Values=$APP_SECRET,rds! --query 'SecretList[].Name' --output text 2>/dev/null | tr '\t' ' ')"
show "IAM 역할" "$(for r in $CLUSTER_ROLE $NODE_ROLE $WAS_ROLE $PROXY_ROLE; do aws iam get-role --role-name $r --query Role.RoleName --output text 2>/dev/null || true; done | tr '\n' ' ')"
show "ECR 저장소 (이미지 수)" "$(for r in "${ECR_REPOS[@]}"; do aws ecr describe-images --repository-name $r --query "length(imageDetails)" --output text 2>/dev/null | sed "s/^/$r:/" || true; done | tr '\n' ' ')"

if [ -f "$KUBECONFIG_EKS" ] && aws eks describe-cluster --name $CLUSTER >/dev/null 2>&1; then
  echo "== kubectl (노드 · NodePool)"
  k get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type,topology.kubernetes.io/zone 2>&1 || true
fi
