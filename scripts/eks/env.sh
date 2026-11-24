#!/usr/bin/env bash
# ④ EKS Auto Mode — AWS 스크립트 공통 설정 (다른 스크립트가 source 한다)
# 모든 자원에 태그 Project=booklog-eks를 붙이고, 조회 · 삭제도 이 태그(와 클러스터 이름)로만 한다.
#   ③(Project=booklog)과 태그를 나눈 이유: ③ 스크립트가 Project=booklog VPC를 하나로 가정하고 찾기 때문
#   수업 VPC · 인스턴스는 건드리지 않는다

export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""
# WSL에는 AWS CLI가 없고 Windows의 aws.exe(인증 설정 포함)를 그대로 부른다. 출력의 CR(\r)은 지운다
AWS_EXE="${AWS_EXE:-/mnt/c/Program Files/Amazon/AWSCLIV2/aws.exe}"
aws() { "$AWS_EXE" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
winpath() { wslpath -w "$1"; }   # aws.exe에 넘기는 파일 경로는 Windows 형식이어야 함

PROJECT=booklog-eks
CLUSTER=booklog
K8S_VERSION=1.36
AZS=(ap-northeast-2a ap-northeast-2c)
VPC_CIDR=10.1.0.0/16                       # ③ 10.0.0.0/16과 겹치지 않게
PUBLIC_CIDRS=(10.1.0.0/24 10.1.1.0/24)     # ALB (2a, 2c)
PRIVATE_CIDRS=(10.1.10.0/24 10.1.11.0/24)  # 노드 · Pod (2a, 2c)
CLUSTER_ROLE=booklog-eks-cluster-role
NODE_ROLE=booklog-eks-node-role
ECR_REPOS=(booklog-was booklog-web)
# Docker Hub → ECR로 옮길 이미지 (태그 = 버전, 같은 다이제스트로 복사)
IMAGES=("booklog-was 1.0.1" "booklog-was 1.1.0" "booklog-was 1.2.0" "booklog-was 1.2.1" "booklog-web 1.0.0")
DOCKERHUB=jeonghyeonseong
KUBECONFIG_EKS="$HOME/.kube/booklog-eks"   # ③ 설정과 섞이지 않게 따로

# RDS (scripts/eks/rds.sh) — Multi-AZ PostgreSQL + RDS Proxy(IAM 인증) + Secrets Manager
DB_ID=booklog                      # RDS 인스턴스 · Proxy · 서브넷 그룹 이름
DB_CLASS=db.t4g.micro
DB_ENGINE_VERSION=18.6             # 서울 RDS의 18 최신 (이미지는 18.7 — RDS에는 아직 없음, 2026-11-24 CLI 확인)
DB_NAME=booklog
DB_ADMIN=booklog_admin             # 관리 계정 (비밀번호는 RDS가 만들어 Secrets Manager에 두고 순환)
DB_APP=booklog_app                 # 앱 계정 (비밀번호 없음, IAM 인증 전용 — migrate의 app.dbrole이 만듦)
APP_SECRET=booklog-eks/app         # JWT_SECRET · DEMO_PASSWORD (.env 값)
WAS_ROLE=booklog-eks-was-role      # was Pod(Pod Identity): Proxy 접속(rds-db:connect) + 비밀 읽기
PROXY_ROLE=booklog-eks-proxy-role  # Proxy → RDS 접속(rds-db:connect)
RDS_CA_URL=https://truststore.pki.rds.amazonaws.com/ap-northeast-2/ap-northeast-2-bundle.pem   # migrate → RDS 직접 TLS 검증용 (공개 인증서)

db_endpoint()    { aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null; }
proxy_endpoint() { aws rds describe-db-proxies --db-proxy-name $DB_ID --query 'DBProxies[0].Endpoint' --output text 2>/dev/null; }
admin_secret_arn() { aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text 2>/dev/null; }
app_secret_arn() { aws secretsmanager describe-secret --secret-id $APP_SECRET --query ARN --output text 2>/dev/null; }

tagspec() { echo "ResourceType=$1,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$2}]"; }

# 태그로 자원 찾기
vpc_id()    { aws ec2 describe-vpcs --filters Name=tag:Project,Values=$PROJECT --query 'Vpcs[0].VpcId' --output text; }
subnet_ids() { aws ec2 describe-subnets --filters Name=tag:Project,Values=$PROJECT Name=tag:Tier,Values=$1 --query 'Subnets[].SubnetId' --output text; }
nat_id()    { aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=$PROJECT Name=state,Values=pending,available --query 'NatGateways[0].NatGatewayId' --output text; }
account_id() { aws sts get-caller-identity --query Account --output text; }
registry()  { echo "$(account_id).dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com"; }

# 화면 · 문서에 계정 ID와 내 IP를 남기지 않는다
#   계정 ID = 앞뒤가 16진수가 아닌 12자리 숫자 (sha256 다이제스트 안의 숫자는 건드리지 않음)
mask() { sed -E -e 's/(^|[^0-9a-f])[0-9]{12}([^0-9a-f]|$)/\1************\2/g' -e 's/([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+\/32/\1.x\/32/g'; }
my_ip() { curl -s -4 https://checkip.amazonaws.com | tr -d '\n'; }

# kubectl은 ④ 전용 kubeconfig로
k() { KUBECONFIG="$KUBECONFIG_EKS" kubectl "$@"; }
