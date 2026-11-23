#!/usr/bin/env bash
# ③ EC2 kubeadm 클러스터 — AWS 스크립트 공통 설정 (다른 스크립트가 source 한다)
# 모든 자원에 태그 Project=booklog를 붙이고, 조회 · 삭제도 이 태그로만 한다 (수업 VPC · 인스턴스는 건드리지 않음)

export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_PAGER=""
# WSL에는 AWS CLI가 없고 Windows의 aws.exe(인증 설정 포함)를 그대로 부른다. 출력의 CR(\r)은 지운다
AWS_EXE="${AWS_EXE:-/mnt/c/Program Files/Amazon/AWSCLIV2/aws.exe}"
aws() { "$AWS_EXE" "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
winpath() { wslpath -w "$1"; }   # aws.exe에 넘기는 파일 경로는 Windows 형식이어야 함

PROJECT=booklog
AZ=ap-northeast-2a                        # t3a.medium은 서울에서 2a · 2c만 제공
VPC_CIDR=10.0.0.0/16
SUBNET_CIDR=10.0.1.0/24
INSTANCE_TYPE=t3a.medium
ROOT_GB=20
AMI_OWNER=792107900819                    # Rocky Linux 공식 계정
AMI_NAME='Rocky-9-EC2-Base-9.9-20261112.0.x86_64'
KEY_NAME=booklog-k8s
KEY_FILE="$HOME/.ssh/booklog-k8s"         # 개인 키는 WSL에만 (권한 600, 저장소 밖)
SSH_USER=rocky
WEB_NODEPORT=30080                        # web Service의 NodePort (밖에서 열 포트는 이것 하나)

# 노드: 이름 · 사설 IP · 역할
NODES=("cp 10.0.1.10 control-plane" "worker1 10.0.1.11 worker" "worker2 10.0.1.12 worker")

TAGS="Key=Project,Value=$PROJECT"
tagspec() { echo "ResourceType=$1,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$2}]"; }

# 태그로 자원 찾기
vpc_id()    { aws ec2 describe-vpcs --filters Name=tag:Project,Values=$PROJECT --query 'Vpcs[0].VpcId' --output text; }
sg_id()     { aws ec2 describe-security-groups --filters Name=tag:Project,Values=$PROJECT --query 'SecurityGroups[0].GroupId' --output text; }
instances() { aws ec2 describe-instances --filters Name=tag:Project,Values=$PROJECT "Name=instance-state-name,Values=${1:-pending,running,stopping,stopped}" --query 'Reservations[].Instances[].InstanceId' --output text; }

# 내 공인 IP (보안 그룹 22 · NodePort 허용 대상). 화면 · 문서에는 마지막 자리를 가린다
my_ip()   { curl -s -4 https://checkip.amazonaws.com | tr -d '\n'; }
mask_ip() { sed -E 's/([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/\1.x/g'; }
