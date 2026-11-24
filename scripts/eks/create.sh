#!/usr/bin/env bash
# ④ EKS Auto Mode 클러스터 만들기:
#   VPC → 서브넷 4개(퍼블릭 2: ALB, 프라이빗 2: 노드) · 태그 → IGW · 라우팅 → regional NAT
#   → IAM 역할 2개 → 클러스터(Auto Mode) → kubeconfig → 노드 Access Entry → 클러스터 공통 매니페스트(k8s/cluster-eks)
# 사용: scripts/eks/create.sh   (이미 Project=booklog-eks VPC가 있으면 아무것도 하지 않고 멈춤)
# ECR은 scripts/eks/ecr.sh (클러스터와 따로 — 클러스터를 지웠다 만들어도 이미지는 유지할 수 있게)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/eks/env.sh

[ "$(vpc_id)" = "None" ] || { echo "이미 Project=$PROJECT VPC가 있음: $(vpc_id) → 중단 (scripts/eks/status.sh로 확인)"; exit 1; }
MYIP=$(my_ip); [ -n "$MYIP" ] || { echo "내 공인 IP를 못 가져옴"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== VPC · 인터넷 게이트웨이"
VPC=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --tag-specifications "$(tagspec vpc $PROJECT-vpc)" --query Vpc.VpcId --output text)
aws ec2 wait vpc-available --vpc-ids $VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'
IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tagspec internet-gateway $PROJECT-igw)" --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
echo "VPC $VPC  IGW $IGW"

echo "== 서브넷 (퍼블릭: ALB용 kubernetes.io/role/elb=1 / 프라이빗: 노드용 kubernetes.io/role/internal-elb=1)"
mksubnet() { # tier cidr az elb-tag
  aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$PROJECT-$1-${3: -2}},{Key=Tier,Value=$1},{Key=$4,Value=1}]" \
    --query Subnet.SubnetId --output text; }
PUB=(); PRI=()
for i in 0 1; do
  PUB+=("$(mksubnet public  ${PUBLIC_CIDRS[$i]}  ${AZS[$i]} kubernetes.io/role/elb)")
  PRI+=("$(mksubnet private ${PRIVATE_CIDRS[$i]} ${AZS[$i]} kubernetes.io/role/internal-elb)")
done
echo "퍼블릭 ${PUB[*]}  프라이빗 ${PRI[*]}"

echo "== 라우팅: 퍼블릭 → IGW"
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tagspec route-table $PROJECT-public-rt)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
for s in "${PUB[@]}"; do aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $s >/dev/null; done

echo "== regional NAT (서브넷 · EIP 지정 없음, 노드가 생기는 AZ로 자동 확장 — 확장 전에는 다른 AZ의 NAT로 처리)"
NAT=$(aws ec2 create-nat-gateway --vpc-id $VPC --availability-mode regional \
  --tag-specifications "$(tagspec natgateway $PROJECT-nat)" --query NatGateway.NatGatewayId --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT
aws ec2 describe-nat-gateways --nat-gateway-ids $NAT --query 'NatGateways[0].[NatGatewayId,State,AvailabilityMode]' --output text

echo "== 라우팅: 프라이빗 → regional NAT"
RT_PRI=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(tagspec route-table $PROJECT-private-rt)" --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $RT_PRI --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT >/dev/null
for s in "${PRI[@]}"; do aws ec2 associate-route-table --route-table-id $RT_PRI --subnet-id $s >/dev/null; done

echo "== IAM 역할 (신뢰 정책 · 관리형 정책: EKS automode-get-started-cli)"
cat >"$TMP/cluster-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}
EOF
cat >"$TMP/node-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
mkrole() { # name trust-file policies...
  aws iam create-role --role-name $1 --assume-role-policy-document "file://$(winpath "$2")" --tags Key=Project,Value=$PROJECT >/dev/null
  for p in "${@:3}"; do aws iam attach-role-policy --role-name $1 --policy-arn arn:aws:iam::aws:policy/$p; done
  echo "$1: ${*:3}"; }
mkrole $CLUSTER_ROLE "$TMP/cluster-trust.json" AmazonEKSClusterPolicy AmazonEKSComputePolicy AmazonEKSBlockStoragePolicyV2 AmazonEKSLoadBalancingPolicy AmazonEKSNetworkingPolicy
mkrole $NODE_ROLE "$TMP/node-trust.json" AmazonEKSWorkerNodeMinimalPolicy AmazonEC2ContainerRegistryPullOnly
CLUSTER_ROLE_ARN=$(aws iam get-role --role-name $CLUSTER_ROLE --query Role.Arn --output text)
NODE_ROLE_ARN=$(aws iam get-role --role-name $NODE_ROLE --query Role.Arn --output text)
sleep 15   # IAM 전파 대기 (방금 만든 역할을 EKS가 바로 못 찾는 경우 방지)

echo "== 클러스터 $CLUSTER (Kubernetes $K8S_VERSION, Auto Mode) — 보통 10~15분"
cat >"$TMP/cluster.json" <<EOF
{
  "name": "$CLUSTER",
  "version": "$K8S_VERSION",
  "roleArn": "$CLUSTER_ROLE_ARN",
  "resourcesVpcConfig": {
    "subnetIds": ["${PRI[0]}", "${PRI[1]}"],
    "endpointPublicAccess": true,
    "publicAccessCidrs": ["$MYIP/32"],
    "endpointPrivateAccess": true
  },
  "computeConfig": {"enabled": true, "nodeRoleArn": "$NODE_ROLE_ARN", "nodePools": ["system"]},
  "kubernetesNetworkConfig": {"elasticLoadBalancing": {"enabled": true}},
  "storageConfig": {"blockStorage": {"enabled": true}},
  "accessConfig": {"authenticationMode": "API", "bootstrapClusterCreatorAdminPermissions": true},
  "tags": {"Project": "$PROJECT"}
}
EOF
aws eks create-cluster --cli-input-json "file://$(winpath "$TMP/cluster.json")" --query 'cluster.[name,status,version]' --output text
aws eks wait cluster-active --name $CLUSTER
aws eks describe-cluster --name $CLUSTER --query 'cluster.{status:status,version:version,platform:platformVersion,compute:computeConfig,endpoint:resourcesVpcConfig.{public:endpointPublicAccess,private:endpointPrivateAccess,cidrs:publicAccessCidrs},auth:accessConfig.authenticationMode}' --output json | mask

echo "== kubeconfig ($KUBECONFIG_EKS) — 토큰은 aws.exe가 발급 (WSL에는 aws 명령이 없어 경로를 aws.exe로 고정)"
mkdir -p "$(dirname "$KUBECONFIG_EKS")"
aws eks update-kubeconfig --name $CLUSTER --kubeconfig "$(winpath "$KUBECONFIG_EKS")" --alias booklog-eks | mask
sed -i -e 's/\r$//' -e "s#command: aws\$#command: $AWS_EXE#" "$KUBECONFIG_EKS"; chmod 600 "$KUBECONFIG_EKS"
k get nodes -o wide || true   # system 풀 노드는 애드온 Pod가 필요할 때 생김

echo "== Access Entry (내 IAM 사용자: 클러스터 생성자 자동 관리자 / 노드 역할: EC2 유형 · AmazonEKSAutoNodePolicy)"
if ! aws eks describe-access-entry --cluster-name $CLUSTER --principal-arn "$NODE_ROLE_ARN" >/dev/null 2>&1; then
  aws eks create-access-entry --cluster-name $CLUSTER --principal-arn "$NODE_ROLE_ARN" --type EC2 >/dev/null
  aws eks associate-access-policy --cluster-name $CLUSTER --principal-arn "$NODE_ROLE_ARN" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAutoNodePolicy --access-scope type=cluster >/dev/null
  echo "노드 역할 Access Entry 생성"
fi
for p in $(aws eks list-access-entries --cluster-name $CLUSTER --query 'accessEntries[]' --output text); do
  printf '%s  %s\n' "$(echo $p | mask)" "$(aws eks list-associated-access-policies --cluster-name $CLUSTER --principal-arn $p --query 'associatedAccessPolicies[].policyArn' --output text | sed 's#.*/##')"
done

echo "== 클러스터 공통 매니페스트: NodeClass · NodePool · StorageClass · IngressClass · NetworkPolicy 컨트롤러"
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text)
sed -e "s/CLUSTER_SECURITY_GROUP_ID/$CLUSTER_SG/" -e "s/NODE_ROLE_NAME/$NODE_ROLE/" k8s/cluster-eks/*.yaml | k apply -f -
echo "== 완료"
scripts/eks/status.sh
