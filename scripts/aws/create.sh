#!/usr/bin/env bash
# ③ 클러스터용 AWS 자원 만들기: VPC → 서브넷 → IGW · 라우팅 → 보안 그룹 → 키 페어 → EC2 3대
# 사용: scripts/aws/create.sh   (이미 Project=booklog VPC가 있으면 아무것도 하지 않고 멈춤)
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "$(vpc_id)" = "None" ] || { echo "이미 Project=$PROJECT VPC가 있음: $(vpc_id) → 중단 (status.sh로 확인)"; exit 1; }
MYIP=$(my_ip); [ -n "$MYIP" ] || { echo "내 공인 IP를 못 가져옴"; exit 1; }
AMI=$(aws ec2 describe-images --owners $AMI_OWNER --filters "Name=name,Values=$AMI_NAME" --query 'Images[0].ImageId' --output text)
[ "$AMI" != "None" ] || { echo "AMI 없음: $AMI_NAME"; exit 1; }
echo "AMI $AMI ($AMI_NAME), 내 IP $(echo $MYIP | mask_ip)"

echo "== VPC · 서브넷 · 인터넷 게이트웨이 · 라우팅"
VPC=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --tag-specifications "$(tagspec vpc $PROJECT-vpc)" --query Vpc.VpcId --output text)
aws ec2 wait vpc-available --vpc-ids $VPC
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'
SUBNET=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block $SUBNET_CIDR --availability-zone $AZ \
  --tag-specifications "$(tagspec subnet $PROJECT-public-2a)" --query Subnet.SubnetId --output text)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET --map-public-ip-on-launch   # 노드에 공인 IP (NAT 없이 이미지 pull · SSH)
IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(tagspec internet-gateway $PROJECT-igw)" --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
RT=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC Name=association.main,Values=true --query 'RouteTables[0].RouteTableId' --output text)
aws ec2 create-tags --resources $RT --tags $TAGS Key=Name,Value=$PROJECT-rt
aws ec2 create-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
echo "VPC $VPC  서브넷 $SUBNET  IGW $IGW  라우팅 $RT"

echo "== 보안 그룹 (필요한 포트만)"
SG=$(aws ec2 create-security-group --group-name $PROJECT-nodes --description "booklog k8s nodes" --vpc-id $VPC \
  --tag-specifications "$(tagspec security-group $PROJECT-nodes)" --query GroupId --output text)
self() { echo "IpProtocol=$1,FromPort=$2,ToPort=$2,UserIdGroupPairs=[{GroupId=$SG,Description=$3}]"; }
mine() { echo "IpProtocol=tcp,FromPort=$1,ToPort=$1,IpRanges=[{CidrIp=$MYIP/32,Description=$2}]"; }
aws ec2 authorize-security-group-ingress --group-id $SG --ip-permissions \
  "$(self tcp 6443 'kube-apiserver from nodes')" \
  "$(self tcp 10250 'kubelet API between nodes')" \
  "$(self udp 4789 'Calico VXLAN between nodes')" \
  "$(mine 22 'my-ip SSH')" \
  "$(mine $WEB_NODEPORT 'my-ip web NodePort')" >/dev/null
echo "SG $SG"

echo "== 키 페어 (개인 키는 WSL $KEY_FILE 에만)"
if [ ! -f "$KEY_FILE" ]; then
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  ssh-keygen -q -t ed25519 -N '' -C "$KEY_NAME" -f "$KEY_FILE"
fi
aws ec2 import-key-pair --key-name $KEY_NAME --public-key-material "fileb://$(winpath "$KEY_FILE.pub")" \
  --tag-specifications "$(tagspec key-pair $KEY_NAME)" --query KeyFingerprint --output text | sed 's/^/지문 /'

echo "== EC2 3대 (사설 IP 고정, cloud-init으로 호스트 이름, IMDSv2, 크레딧 standard, 20GiB gp3 암호화)"
UD=$(mktemp --suffix=.yaml)
for n in "${NODES[@]}"; do
  read -r NAME IP ROLE <<<"$n"
  cat >"$UD" <<EOF
#cloud-config
# hostname 키만으로는 EC2 메타데이터 이름(ip-10-0-1-10...)이 남아서, 직접 바꾸고 cloud-init이 다시 덮어쓰지 않게 고정
runcmd:
  - [ hostnamectl, set-hostname, $NAME ]
  - [ sh, -c, 'echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-booklog-hostname.cfg' ]
  - [ sh, -c, 'printf "10.0.1.10 cp\n10.0.1.11 worker1\n10.0.1.12 worker2\n" >> /etc/hosts' ]
EOF
  ID=$(aws ec2 run-instances --image-id $AMI --instance-type $INSTANCE_TYPE --key-name $KEY_NAME \
    --subnet-id $SUBNET --private-ip-address $IP --security-group-ids $SG \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$ROOT_GB,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}" \
    --credit-specification CpuCredits=standard \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --user-data "file://$(winpath "$UD")" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$PROJECT-$NAME},{Key=Role,Value=$ROLE}]" \
                         "ResourceType=volume,Tags=[{Key=Project,Value=$PROJECT},{Key=Name,Value=$PROJECT-$NAME-root}]" \
    --query 'Instances[0].InstanceId' --output text)
  echo "$NAME $IP → $ID"
done
rm -f "$UD"
aws ec2 wait instance-running --instance-ids $(instances pending,running)
echo "== 완료"
"$(dirname "$0")/status.sh"
