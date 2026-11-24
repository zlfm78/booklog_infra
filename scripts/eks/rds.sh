#!/usr/bin/env bash
# ④ DB를 RDS로: create.sh(VPC · 클러스터) 다음에 실행한다. 클러스터와 수명이 달라 스크립트를 나눔 (ecr.sh와 같은 원칙)
#   1) DB 서브넷 그룹(프라이빗 2a · 2c)   2) 보안 그룹: Proxy · RDS (클러스터 보안 그룹에서 5432만)
#   3) RDS PostgreSQL Multi-AZ — 관리 계정 비밀번호는 RDS가 만들어 Secrets Manager에 두고 순환(기본 7일), IAM 인증 켬
#   4) RDS Proxy — 클라이언트 · DB 쪽 모두 IAM 인증(end-to-end IAM, 비밀번호 없음), TLS 필수
#   5) Secrets Manager: 앱 비밀(JWT_SECRET · DEMO_PASSWORD, .env 값)
#   6) was 역할 + Pod Identity 연결   7) Secrets Store CSI Driver + AWS 제공자 (EKS 애드온)
# 사용: scripts/eks/rds.sh   (이미 있는 자원은 건너뜀 → 실패하면 다시 실행)
# 비밀 값은 화면 · 파일 · 저장소에 남기지 않는다 (임시 파일은 끝나면 지움, 출력은 mask)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/eks/env.sh
VPC=$(vpc_id); [ "$VPC" != "None" ] || { echo "VPC 없음 → scripts/eks/create.sh 먼저"; exit 1; }
aws eks describe-cluster --name $CLUSTER >/dev/null 2>&1 || { echo "클러스터 없음 → scripts/eks/create.sh 먼저"; exit 1; }
ACCOUNT=$(account_id)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
read -r -a PRI <<<"$(subnet_ids private)"
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)

echo "== 1) DB 서브넷 그룹 (프라이빗 ${PRI[*]})"
aws rds describe-db-subnet-groups --db-subnet-group-name $DB_ID >/dev/null 2>&1 ||
  aws rds create-db-subnet-group --db-subnet-group-name $DB_ID --db-subnet-group-description "booklog RDS (private 2a 2c)" \
    --subnet-ids "${PRI[@]}" --tags Key=Project,Value=$PROJECT --query 'DBSubnetGroup.DBSubnetGroupName' --output text

echo "== 2) 보안 그룹: Proxy ← 노드(클러스터 SG) 5432 / RDS ← Proxy 5432 · 노드 5432(migrate가 관리 계정으로 직접)"
sg() { # name desc → id (있으면 그대로)
  local id; id=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=$1 --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then
    id=$(aws ec2 create-security-group --vpc-id $VPC --group-name $1 --description "$2" --tag-specifications "$(tagspec security-group $1)" --query GroupId --output text)
  fi; echo $id; }
allow() { aws ec2 authorize-security-group-ingress --group-id $1 --ip-permissions "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$2,Description=$3}]" >/dev/null 2>&1 || true; }
PROXY_SG=$(sg $PROJECT-proxy-sg "booklog RDS Proxy: 5432 from EKS nodes")
RDS_SG=$(sg $PROJECT-rds-sg "booklog RDS: 5432 from Proxy and EKS nodes")
allow $PROXY_SG $CLUSTER_SG eks-nodes
allow $RDS_SG $PROXY_SG rds-proxy
allow $RDS_SG $CLUSTER_SG eks-nodes-migrate
for g in $PROXY_SG $RDS_SG; do
  echo "$g $(aws ec2 describe-security-groups --group-ids $g --query 'SecurityGroups[0].[GroupName,IpPermissions[].[FromPort,UserIdGroupPairs[].GroupId]]' --output text | tr '\t\n' '  ')"
done

echo "== 3) RDS $DB_ID ($DB_CLASS, PostgreSQL $DB_ENGINE_VERSION, Multi-AZ) — 보통 10~20분"
if ! aws rds describe-db-instances --db-instance-identifier $DB_ID >/dev/null 2>&1; then
  aws rds create-db-instance --db-instance-identifier $DB_ID --engine postgres --engine-version $DB_ENGINE_VERSION \
    --db-instance-class $DB_CLASS --allocated-storage 20 --storage-type gp3 --storage-encrypted \
    --multi-az --db-subnet-group-name $DB_ID --vpc-security-group-ids $RDS_SG --no-publicly-accessible \
    --db-name $DB_NAME --master-username $DB_ADMIN --manage-master-user-password \
    --enable-iam-database-authentication --backup-retention-period 1 --no-deletion-protection \
    --tags Key=Project,Value=$PROJECT --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text
fi
aws rds wait db-instance-available --db-instance-identifier $DB_ID
aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].{status:DBInstanceStatus,engine:EngineVersion,class:DBInstanceClass,multiAZ:MultiAZ,az:AvailabilityZone,standbyAz:SecondaryAvailabilityZone,iamAuth:IAMDatabaseAuthenticationEnabled,public:PubliclyAccessible,encrypted:StorageEncrypted,endpoint:Endpoint.Address,masterSecret:MasterUserSecret.SecretStatus}' --output json | mask
DBI_RESOURCE=$(aws rds describe-db-instances --db-instance-identifier $DB_ID --query 'DBInstances[0].DbiResourceId' --output text)

echo "== 4) RDS Proxy $DB_ID (IAM 인증 end-to-end · TLS 필수)"
cat >"$TMP/proxy-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"rds.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
# Proxy가 DB에 앱 계정으로 IAM 접속할 권한 (대상 = DB 인스턴스 리소스 ID)
cat >"$TMP/proxy-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"rds-db:connect","Resource":"arn:aws:rds-db:$AWS_DEFAULT_REGION:$ACCOUNT:dbuser:$DBI_RESOURCE/$DB_APP"}]}
EOF
aws iam get-role --role-name $PROXY_ROLE >/dev/null 2>&1 ||
  aws iam create-role --role-name $PROXY_ROLE --assume-role-policy-document "file://$(winpath "$TMP/proxy-trust.json")" --tags Key=Project,Value=$PROJECT >/dev/null
aws iam put-role-policy --role-name $PROXY_ROLE --policy-name rds-connect --policy-document "file://$(winpath "$TMP/proxy-policy.json")"
PROXY_ROLE_ARN=$(aws iam get-role --role-name $PROXY_ROLE --query Role.Arn --output text)
if ! aws rds describe-db-proxies --db-proxy-name $DB_ID >/dev/null 2>&1; then
  sleep 10   # IAM 전파
  aws rds create-db-proxy --db-proxy-name $DB_ID --engine-family POSTGRESQL --role-arn $PROXY_ROLE_ARN \
    --default-auth-scheme IAM_AUTH --require-tls --vpc-subnet-ids "${PRI[@]}" --vpc-security-group-ids $PROXY_SG \
    --tags Key=Project,Value=$PROJECT --query 'DBProxy.[DBProxyName,Status]' --output text
fi
for i in $(seq 1 60); do
  st=$(aws rds describe-db-proxies --db-proxy-name $DB_ID --query 'DBProxies[0].Status' --output text)
  [ "$st" = available ] && break; sleep 15
done
echo "Proxy 상태: $st"
aws rds register-db-proxy-targets --db-proxy-name $DB_ID --db-instance-identifiers $DB_ID >/dev/null 2>&1 || true
aws rds describe-db-proxies --db-proxy-name $DB_ID --query 'DBProxies[0].{status:Status,auth:DefaultAuthScheme,tls:RequireTLS,endpoint:Endpoint}' --output json | mask
PROXY_RESOURCE=$(aws rds describe-db-proxies --db-proxy-name $DB_ID --query 'DBProxies[0].DBProxyArn' --output text | sed 's#.*:##')
echo "(대상 상태는 앱 계정이 생긴 뒤 — deploy 후 — AVAILABLE이 됨)"

echo "== 5) Secrets Manager: $APP_SECRET (JWT_SECRET · DEMO_PASSWORD, .env 값 — 화면에 출력하지 않음)"
( set -a; . ./.env; set +a
  python3 -c 'import json,os; print(json.dumps({k: os.environ[k] for k in ("JWT_SECRET","DEMO_PASSWORD")}))' >"$TMP/app-secret.json" )
if aws secretsmanager describe-secret --secret-id $APP_SECRET >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id $APP_SECRET --secret-string "file://$(winpath "$TMP/app-secret.json")" >/dev/null
else
  aws secretsmanager create-secret --name $APP_SECRET --secret-string "file://$(winpath "$TMP/app-secret.json")" --tags Key=Project,Value=$PROJECT >/dev/null
fi
rm -f "$TMP/app-secret.json"
ADMIN_SECRET_ARN=$(admin_secret_arn); APP_SECRET_ARN=$(app_secret_arn)
aws secretsmanager list-secrets --filters Key=name,Values=$APP_SECRET,rds! --query 'SecretList[].[Name,RotationEnabled,RotationRules.AutomaticallyAfterDays]' --output text | mask

echo "== 6) was 역할 $WAS_ROLE (Pod Identity: booklog/was) — Proxy에 앱 계정으로 접속 + 비밀 2개 읽기"
cat >"$TMP/was-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF
# rds-db:connect 대상 = Proxy 리소스 ID(prx-…) / 앱 계정: "이 Proxy를 통해 booklog_app으로만"
cat >"$TMP/was-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"rds-db:connect","Resource":"arn:aws:rds-db:$AWS_DEFAULT_REGION:$ACCOUNT:dbuser:$PROXY_RESOURCE/$DB_APP"},
 {"Effect":"Allow","Action":["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"],"Resource":["$ADMIN_SECRET_ARN","$APP_SECRET_ARN"]}]}
EOF
aws iam get-role --role-name $WAS_ROLE >/dev/null 2>&1 ||
  aws iam create-role --role-name $WAS_ROLE --assume-role-policy-document "file://$(winpath "$TMP/was-trust.json")" --tags Key=Project,Value=$PROJECT >/dev/null
aws iam put-role-policy --role-name $WAS_ROLE --policy-name booklog-was --policy-document "file://$(winpath "$TMP/was-policy.json")"
WAS_ROLE_ARN=$(aws iam get-role --role-name $WAS_ROLE --query Role.Arn --output text)
if [ -z "$(aws eks list-pod-identity-associations --cluster-name $CLUSTER --namespace booklog --service-account was --query 'associations[].associationId' --output text)" ]; then
  aws eks create-pod-identity-association --cluster-name $CLUSTER --namespace booklog --service-account was --role-arn $WAS_ROLE_ARN >/dev/null
fi
aws eks list-pod-identity-associations --cluster-name $CLUSTER --query 'associations[].[namespace,serviceAccount,associationId]' --output text

echo "== 7) EKS 애드온 aws-secrets-store-csi-driver-provider (드라이버 포함, K8s Secret 동기화 · 순환 1분 확인)"
cat >"$TMP/csi.json" <<'EOF'
{"secrets-store-csi-driver":{"syncSecret":{"enabled":true},"enableSecretRotation":true,"rotationPollInterval":"1m"}}
EOF
if ! aws eks describe-addon --cluster-name $CLUSTER --addon-name aws-secrets-store-csi-driver-provider >/dev/null 2>&1; then
  aws eks create-addon --cluster-name $CLUSTER --addon-name aws-secrets-store-csi-driver-provider \
    --configuration-values "file://$(winpath "$TMP/csi.json")" --tags Project=$PROJECT >/dev/null
fi
aws eks wait addon-active --cluster-name $CLUSTER --addon-name aws-secrets-store-csi-driver-provider
aws eks describe-addon --cluster-name $CLUSTER --addon-name aws-secrets-store-csi-driver-provider --query 'addon.[addonName,addonVersion,status]' --output text
k get csidriver secrets-store.csi.k8s.io 2>&1 | tail -1
echo "== 완료 → scripts/eks/deploy.sh"
